%% Note: the #phone.requristr field must always be created with
%% url_to_requristr/1, otherwise functions that match againts
%% requristr, like get_sipuser_location_binding/2 will fail.
%%
%%--------------------------------------------------------------------

-module(phone).

%%--------------------------------------------------------------------
%% External exports
%%--------------------------------------------------------------------
-export([
	 init/0,
	 create/0,
	 create/1,
	 remove_expired_phones/0,
	 get_sipuser_location_binding/2,
	 get_sipuser_locations/1,
	 get_phone/1,
	 list_phones/0,
	 get_user/1,
	 insert_user/4,
	 list_users/0,
	 insert_purge_phone/7,
	 purge_class_phone/2,
	 expired_phones/0,
	 delete_record/1,
	 delete_user/1,
	 set_user_password/2,
	 set_user_flags/2,
	 set_user_numbers/2,
	 set_user_classes/2,
	 insert_user_or_password/2,
	 get_numbers_for_user/1,
	 get_users_for_number/1,
	 list_numbers/0,
	 delete_phone/3,
	 get_phone_with_requri/1
	]).

%%--------------------------------------------------------------------
%% Internal exports
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------
-include("phone.hrl").
-include("siprecords.hrl").

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Macros
%%--------------------------------------------------------------------

%%====================================================================
%% External functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init()
%% Descrip.: start mnesia and use local node as disc node
%% Returns :
%%--------------------------------------------------------------------
init() ->
    mnesia:create_schema([node()]),
    mnesia:start().

%%--------------------------------------------------------------------
%% Function: create()
%%           create(Servers)
%% Descrip.: Put phone, user and numbers tables as disc_copies on
%%           Servers
%% Returns :
%%--------------------------------------------------------------------
create() ->
    create(servers()).

create(Servers) ->
    mnesia:create_table(phone, [{attributes, record_info(fields, phone)},
				{disc_copies, Servers},
				{type, bag}]),
    mnesia:create_table(user, [{attributes, record_info(fields, user)},
			       {disc_copies, Servers}]),
    mnesia:create_table(numbers, [{attributes, record_info(fields, numbers)},
				  {disc_copies, Servers},
				  {index, [number]},
				  {type, bag}]).

servers() ->
    sipserver:get_env(databaseservers).

%%--------------------------------------------------------------------
%% Function: remove_expired_phones()
%% Descrip.: remove phone entries in DB that should no longer be
%%           present
%% Returns : true | error
%%--------------------------------------------------------------------
remove_expired_phones() ->
    case expired_phones() of
	{ok, Expired} ->
	    remove_phones(Expired),
	    true;
	{aborted, {no_exists, Table}} ->
	    logger:log(error, "Location: Mnesia says that table '~p' does not exist"
		       " - did you bootstrap Yxa? (See README file)", [Table]),
	    error;
	{aborted, Reason} ->
	    logger:log(error, "Location: phone:expired_phones() returned unknown result : ~p", [Reason]),
	    error
    end.


remove_phones(ExpiredPhones) ->
    F = fun({User, Location, Class}) ->
		URL = if
			  is_list(Location) ->
			      sipurl:parse(Location);
			  true ->
			      none
		      end,
		if
		    is_record(URL, sipurl) ->
			logger:log(normal, "Location: User ~p ~p location ~p has expired",
				   [User, Class, sipurl:print(URL)]);
		    true ->
			logger:log(normal, "Location: User ~p ~p (unrecognized) location ~p has expired",
				   [User, Class, Location])
		end,
		delete_phone(User, Location, Class)
	end,
    lists:foreach(F, ExpiredPhones).

%%--------------------------------------------------------------------
%% Function: insert_purge_phone(SipUser, Flags, Class, Expire,
%%                              Address, CallId, CSeq)
%%           SipUser =
%%           Flags   = list of {Name,Value}
%%           Name    = string() ?
%%           Value   = string() ?
%%           Class   = dynamic | ... ?
%%           Expire  = integer()
%%           Address = sipurl record()
%%           CallId  = string()
%%           CSeq    = integer()
%% Descrip.: Remove a certain SipUser -> location mapping. Then create
%%           a new entry with a new Expire value
%% Returns : The result of the mnesia:transaction()
%%--------------------------------------------------------------------
insert_purge_phone(SipUser, Flags, Class, Expire, Address, CallId, CSeq) when is_record(Address, sipurl) ->
    %% We store locations as strings in the location database, since any
    %% datastructure could have to be changed in the future
    LocationStr = sipurl:print(Address),
    %% URIstr is not a valid location for this user, it is used to find the user of
    %% a location, when for example we need to determine if we should proxy a request
    %% without requiring authorization in incomingproxy and appserver.
    URIstr = url_to_requristr(Address),
    Fun = fun() ->
		  A = mnesia:match_object(#phone{number = SipUser,
						 class = Class,
						 requristr = URIstr,
						 _ = '_'}),
		  Delete = fun(O) ->
				   mnesia:delete_object(O)
			   end,
		  lists:foreach(Delete, A),
		  mnesia:write(#phone{number = SipUser,
				      flags = Flags,
				      class = Class,
				      expire = Expire,
				      address = LocationStr,
				      requristr = URIstr,
				      callid = CallId,
				      cseq = CSeq
				     })
	  end,
    mnesia:transaction(Fun).

%%--------------------------------------------------------------------
%% Function: purge_class_phone/2
%% Descrip.: Removes all entrys matching a number (SIP user),
%%           and class from the location database.
%% Returns : The result of the mnesia:transaction()
%% XXX only used in admin_www.erl
%%--------------------------------------------------------------------
purge_class_phone(Number, Class) ->
    Fun = fun() ->
		  A = mnesia:match_object(#phone{number = Number,
						 class = Class,
						 _ = '_'}),
		  Delete = fun(O) ->
				   mnesia:delete_object(O)
			   end,
		  lists:foreach(Delete, A)
	  end,
    mnesia:transaction(Fun).

%%--------------------------------------------------------------------
%% Function:
%% Descrip.:
%% Returns :
%%--------------------------------------------------------------------
insert_user(User, Password, Flags, Classes) ->
    db_util:insert_record(#user{user = User,
				password = Password,
				flags = Flags,
				classes = Classes
			       }).

%%--------------------------------------------------------------------
%% Function:
%% Descrip.:
%% Returns :
%% XXX only used in admin_www.erl
%%--------------------------------------------------------------------
insert_user_or_password(User, Password) ->
    Fun = fun() ->
		  A = mnesia:read({user, User}),
 		  %% A = mnesia:match_object(#user{user = User,  _ = '_'}),
		  case A of
		      [] ->
			  mnesia:write(#user{user = User, password = Password,
					     flags = [], classes = []});
		      [Entry] ->
			  mnesia:write(Entry#user{password = Password});
		      _ ->
			  mnesia:abort(illegal)
		  end
	  end,
    mnesia:transaction(Fun).

%%--------------------------------------------------------------------
%% Function: list_xxxs()
%%           xxx = phone | user | number
%% Descrip.: return database contents of the table named xxx as a list
%%           - this code is mainly intended for debugging
%% Returns : list of xxx record()
%%--------------------------------------------------------------------
list_phones() ->
    db_util:tab_to_list(phone).

list_users() ->
    db_util:tab_to_list(user).

list_numbers() ->
    db_util:tab_to_list(numbers).

%%--------------------------------------------------------------------
%% Function: get_sipuser_location_binding(SipUser, Location)
%%           SipUser  = string()
%%           Location = sipurl record()
%% Descrip.: Look for a phone record() that maps SipUser to Location.
%% Returns : {atomic, [LocRec]} | {atomic, []} | ....
%%           LocRec = phone record()
%%--------------------------------------------------------------------
get_sipuser_location_binding(SipUser, Location) when is_list(SipUser), is_record(Location, sipurl) ->
    Now = util:timestamp(),
    LocationStr = url_to_requristr(Location),

    F = fun() ->
		mnesia:select(phone,
			      [{#phone{number = SipUser,
				       requristr = LocationStr,
				       _ = '_'},
				[{'>', {element, #phone.expire, '$_'}, Now}],
				['$_']
			       }])
	end,
    case mnesia:transaction(F) of
	{atomic, L} ->
	    {atomic, L};
	Unknown ->
	    logger:log(error, "Location: get_sipuser_location_binding got unknown result from Mnesia : ~p", [Unknown]),
	    Unknown
    end.


%%--------------------------------------------------------------------
%% Function: get_sipuser_locations(SipUser)
%%           SipUser = string()
%% Descrip.: Fetches all locations for a given number (SIP user)
%%           from the location database.
%% Returns : {atomic, Entries} |
%%           the result of the mnesia:transaction()
%%           Entries = phone record()
%%--------------------------------------------------------------------
get_sipuser_locations(SipUser) when is_list(SipUser) ->
    Now = util:timestamp(),

    F = fun() ->
		mnesia:select(phone, [{#phone{number = SipUser, _ = '_'},
				       [{'>', {element, #phone.expire, '$_'}, Now}],
				       ['$_']
				      }])
	end,
    case mnesia:transaction(F) of
	{atomic, L} ->
	    {atomic, L};
	Unknown ->
	    logger:log(error, "Location: get_sipuser_locations got unknown result from Mnesia : ~p", [Unknown]),
	    Unknown
    end.

%%--------------------------------------------------------------------
%% Function: get_phone(SipUser)
%%           SipUser = string()
%% Descrip.: Fetches all locations for a given number (SIP user)
%%           from the location database.
%% Returns : {ok, Entries} |
%%           the result of the mnesia:transaction()
%%           Entries = list() of siplocationdb_e record()
%% XXX deprecated - should be replaced by get_sipuser_locations/1
%%--------------------------------------------------------------------
get_phone(SipUser) when is_list(SipUser) ->
    Now = util:timestamp(),

    F = fun() ->
		mnesia:select(phone, [{#phone{number = SipUser, _ = '_'},
				       [{'>', {element, #phone.expire, '$_'}, Now}],
				       [{{{element, #phone.address, '$_'},
					  {element, #phone.flags, '$_'},
					  {element, #phone.class, '$_'},
					  {element, #phone.expire, '$_'}
					 }}]
				      }])
	end,
    {atomic, L} = mnesia:transaction(F),
    %% Convert the location strings stored in the database to sipurl record format.
    %% We can't store the locations as sipurl records in the database in case we
    %% have to change something in the sipurl record.
    Rewrite = fun(Entry) ->
		      {LocationStr, Flags, Class, Expire} = Entry,
		      #siplocationdb_e{address=sipurl:parse(LocationStr), flags=Flags,
				       class=Class, expire=Expire}
	      end,
    {ok, lists:map(Rewrite, L)}.

%%--------------------------------------------------------------------
%% Function:
%% Descrip.:
%% Returns : list() of {Password, Flags, Classes}
%%           with fields are taken from user record()
%%--------------------------------------------------------------------
get_user(User) ->
    F = fun() ->
		[ {E#user.password, E#user.flags, E#user.classes} ||
		    E <- mnesia:read({user, User}) ]
	end,
    mnesia:transaction(F).


%%--------------------------------------------------------------------
%% Function:
%% Descrip.:
%% Returns : list() of #numbers.number field values XXX
%%--------------------------------------------------------------------
get_numbers_for_user(User) ->
    F = fun() ->
		[ E#numbers.number || E <- mnesia:read({numbers, User}) ]
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function:
%% Descrip.:
%% Returns : list() of #numbers.user field values XXX
%%--------------------------------------------------------------------
get_users_for_number(Number) ->
    F = fun() ->
		[ E#numbers.user || E <- mnesia:match_object(#numbers{number = Number,
								      _ = '_'}) ]
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: get_phone_with_requri(URI)
%%           URI = sipurl record()
%% Descrip.: find all users (#phone.number) that use a cretain sip url
%% Returns : {atomic, Users} | {aborted, Reason}
%%           Users = list() of #phone.number values
%% XXX this function is inefficient, as no keys are used during search
%%--------------------------------------------------------------------
get_phone_with_requri(URI) when is_record(URI, sipurl) ->
    ReqURIstr = url_to_requristr(URI),
    F = fun() ->
		[ E#phone.number || E <- mnesia:match_object(#phone{requristr = ReqURIstr,
								    _ = '_'}) ]
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function:
%% Descrip.:
%% Returns :
%% XXX only used in admin_www.erl
%%--------------------------------------------------------------------
set_user_password(User, Password) ->
    F = fun() ->
		L = mnesia:read({user, User}),
		Update = fun(Obj) ->
				 mnesia:write(Obj#user{password = Password})
			 end,
		lists:foreach(Update, L)
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function:
%% Descrip.:
%% Returns :
%% XXX only used in admin_www.erl
%%--------------------------------------------------------------------
set_user_flags(User, Flags) ->
    F = fun() ->
		A = mnesia:read({user, User}),
		Update = fun(Obj) ->
				 mnesia:write(Obj#user{flags = Flags})
			 end,
		lists:foreach(Update, A)
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function:
%% Descrip.:
%% Returns :
%% XXX only used in admin_www.erl
%%--------------------------------------------------------------------
set_user_numbers(User, Numbers) ->
    F = fun() ->
		A = mnesia:read({numbers, User}),
		Delete = fun(Obj) ->
				 mnesia:delete_object(Obj)
			 end,
		lists:foreach(Delete, A),
		Update = fun(Number) ->
				 mnesia:write(#numbers{number = Number,
						       user = User})
			 end,
		lists:foreach(Update, Numbers)
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function:
%% Descrip.:
%% Returns :
%% XXX only used in admin_www.erl
%%--------------------------------------------------------------------
set_user_classes(User, Classes) ->
    F = fun() ->
		A = mnesia:read({user, User}),
		Update = fun(Obj) ->
				 mnesia:write(Obj#user{classes = Classes})
			 end,
		lists:foreach(Update, A)
	end,
    mnesia:transaction(F).

%%--------------------------------------------------------------------
%% Function: expired_phones()
%% Descrip.: Finds all expired entrys from the location database.
%% Returns : {ok, Entries} |
%%           the result of the Mnesia transaction
%%           Entries = list() of {Number, Address, Class} tuples()
%%--------------------------------------------------------------------
expired_phones() ->
    Now = util:timestamp(),

    F = fun() ->
		mnesia:select(phone, [{#phone{_ = '_'},
				       [{'<', {element, #phone.expire, '$_'}, Now}],
				       [{{{element, #phone.number, '$_'},
					  {element, #phone.address, '$_'},
					  {element, #phone.class, '$_'}
					 }}]
				      }])
	end,

    case mnesia:transaction(F) of
	{atomic, L} ->
	    {ok, L};
	Unknown ->
	    logger:log(error, "Location: expired_phones got unknown result from Mnesia : ~p", [Unknown]),
	    Unknown
    end.

%%--------------------------------------------------------------------
%% Function: delete_phone(SipUser, Address, Class)
%%           SipUser = string()
%%           Class   = atom()
%%           Address = term()
%% Descrip.: Removes all entrys matching a number (SIP user), class
%%           and address from the location database. Address can be
%%           whatever - this function should not be depending on being
%%           able to understand Address to remove old records from the
%%           database.
%% Returns : The result of the Mnesia transaction
%% Note    :  used by remove_phones (and remove_expired_phones)
%%--------------------------------------------------------------------
delete_phone(SipUser, Address, Class) when is_list(SipUser), is_atom(Class) ->
    Fun = fun() ->
		  A = mnesia:match_object(#phone{number = SipUser,
						 class = Class,
						 address = Address,
						 _ = '_'}),
		  Delete = fun(O) ->
				   mnesia:delete_object(O)
			   end,
		  lists:foreach(Delete, A)
	  end,
    mnesia:transaction(Fun).

%%--------------------------------------------------------------------
%% Function: delete_record(Obj)
%%           Obj = phone record()
%% Descrip.: remove a single phone record Obj in a bag table
%% Returns :
%%--------------------------------------------------------------------
delete_record(Obj) ->
    db_util:delete_record(Obj).

%%--------------------------------------------------------------------
%% Function:
%% Descrip.:
%% Returns :
%% XXX unused - possibly intended for manual usage
%%--------------------------------------------------------------------
delete_user(User) ->
    delete_with_key(user, User).

delete_with_key(Db, Key) ->
    F = fun() ->
 		mnesia:delete({Db, Key})
 	end,
    Rec = mnesia:transaction(F),
    Rec.

%%====================================================================
%% Behaviour functions
%%====================================================================

%%====================================================================
%% Internal functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: url_to_requristr(URL)
%%           URL = sipurl record()
%% Descrip.: We need to store the location as a searchable string
%%           in order to be able to look up a location to a user.
%%           This string is not used to look up the location of a
%%           user, but rather to see if we are to relay requests
%%           to a destination without challenging and so on.
%% Returns : string()
%%--------------------------------------------------------------------
url_to_requristr(URL) when is_record(URL, sipurl) ->
    Port = siprequest:default_port(URL#sipurl.proto, sipurl:get_port(URL)),
    Host = URL#sipurl.host,
    User = URL#sipurl.user,
    %% sipurl:print/1 is used to create a consistent and therefore
    %% easily matchable string
    sipurl:print(sipurl:new([{proto, "sip"}, {user, User}, {host, Host}, {port, Port}])).
