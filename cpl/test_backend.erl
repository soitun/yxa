%%
%%--------------------------------------------------------------------

-module(test_backend).

%%--------------------------------------------------------------------
%% External exports
%%--------------------------------------------------------------------
-export([
	 %% outgoing
	 get_outgoing_destination/1,

	 %% address-switch
	 'get_address-switch_field'/3,
	 compare_address_or_address_part/2,
	 address_or_address_part_contains/2,
	 is_subdomain/2,

	 %% string-switch
	 'get_string-switch_field'/2,
	 string_is/2,
	 string_contains/2,

	 %% language-switch
	 'get_language-switch_value'/1,
	 language_matches/2,

	 %% priority-switch
	 'get_priority-switch_value'/1,
	 priority_less/2,
	 priority_greater/2,
	 priority_equal/2,

	 %% lookup
	 lookup/4,

	 %% remove-location
	 rm_location/2,

	 %% log
	 log/3,

	 %% mail
	 mail/1,

	 %% time-switch
	 in_time_range/2,

	 %% proxy
	 get_min_ring/0,
	 get_server_max/0,
	 test_proxy_destinations/7
	]).

%%--------------------------------------------------------------------
%% Internal exports
%%--------------------------------------------------------------------
-export([
        ]).

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------
-include("siprecords.hrl").
-include("sipproxy.hrl").
-include("cpl.hrl").

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
%% Function:
%% Descrip.: 
%% Returns : 
%% Note    : 
%%--------------------------------------------------------------------
get_outgoing_destination(Request) ->
    interpret_backend:get_outgoing_destination(Request).


%%--------------------------------------------------------------------
%% Function: 
%% Descrip.: 
%% Returns : 
%% Note    : 
%%--------------------------------------------------------------------
'get_address-switch_field'(Request, Field, SubField) ->
    interpret_backend:'get_address-switch_field'(Request, Field, SubField).

%%--------------------------------------------------------------------
%% Function: 
%% Descrip.: 
%% Returns : 
%% Note    : 
%%--------------------------------------------------------------------
compare_address_or_address_part(ReqVal, Val) ->
    interpret_backend:compare_address_or_address_part(ReqVal, Val).



%%--------------------------------------------------------------------
%% Function: 
%% Descrip.: 
%% Returns : 
%%--------------------------------------------------------------------
address_or_address_part_contains({display, ReqVal}, Val) ->
    interpret_backend:address_or_address_part_contains({display, ReqVal}, Val).


%%--------------------------------------------------------------------
%% Function: 
%% Descrip.: 
%% Returns : 
%%--------------------------------------------------------------------
is_subdomain(Str, SubStr) ->
    interpret_backend:is_subdomain(Str, SubStr).


%%--------------------------------------------------------------------
%% Function: 
%% Descrip.: 
%% Returns : 
%%--------------------------------------------------------------------
'get_string-switch_field'(Request, Field) ->
    interpret_backend:'get_string-switch_field'(Request, Field).


%%--------------------------------------------------------------------
%% Function: 
%% Descrip.: 
%% Returns :
%%--------------------------------------------------------------------
string_is(ReqVal, Val) ->
    interpret_backend:string_is(ReqVal, Val).

string_contains(ReqVal, Val) ->
    interpret_backend:string_contains(ReqVal, Val).

%%--------------------------------------------------------------------
%% Function:
%% Descrip.:
%% Returns :
%%--------------------------------------------------------------------
'get_language-switch_value'(Request) ->
    interpret_backend:'get_language-switch_value'(Request).

language_matches(ReqVal, Val) ->
    interpret_backend:language_matches(ReqVal, Val).
%%--------------------------------------------------------------------
%% Function:
%% Descrip.:
%% Returns :
%% Note    :
%%--------------------------------------------------------------------
'get_priority-switch_value'(Request) ->
    interpret_backend:'get_priority-switch_value'(Request).


priority_less(ReqVal, Val) ->
    interpret_backend:priority_less(ReqVal, Val).

priority_greater(ReqVal, Val) ->
    interpret_backend:priority_greater(ReqVal, Val).

priority_equal(ReqVal, Val) ->
    interpret_backend:priority_equal(ReqVal, Val).

%%--------------------------------------------------------------------
%% Function: 
%% Descrip.: fake lookup result - the same way as in 
%%           test_proxy_destinations(...)
%%           use put(Index, Val) to add suitable returnvalues
%%           Val = notfound | failure | {success, Locations}
%%           Locations = list() of sipurl record()
%% Returns : 
%%--------------------------------------------------------------------
lookup(_Source, _User, _UserURI, _Timeout) ->
    Index = get_next_put(),
    case erase(Index) of
	%% put(Index, {Test, Val})
	notfound -> {notfound, []};
	{success, Locations} -> {success, Locations};
	failure -> {failure, []}
    end.

%%--------------------------------------------------------------------
%% Function: 
%% Descrip.: 
%% Returns : 
%%--------------------------------------------------------------------
rm_location(Locations, URIStr) ->
    interpret_backend:rm_location(Locations, URIStr).

%%--------------------------------------------------------------------
%% Function:
%% Descrip.:
%% Returns :
%%--------------------------------------------------------------------
log(LogAttrs, User, Request) ->
    interpret_backend:log(LogAttrs, User, Request).

%%--------------------------------------------------------------------
%% Function: 
%% Descrip.: 
%% Returns : 
%%--------------------------------------------------------------------
mail(Mail) ->
    interpret_backend:mail(Mail).

%%--------------------------------------------------------------------
%% Function:
%% Descrip.: 
%% Returns : 
%%--------------------------------------------------------------------
in_time_range(Timezone, TimeSwitchCond) ->
    Index = get_next_put(),
    case erase(Index) of
	%% put(Index, {Test, Val})
	CurrentDateTime ->
	    Current = ts_datetime:datetime_to_usec(start, Timezone, CurrentDateTime),
	    interpret_time:in_time_range_test(Timezone, TimeSwitchCond, Current)
    end.

%%--------------------------------------------------------------------
%% Function: 
%% Descrip.: 
%% Returns : 
%%--------------------------------------------------------------------
get_min_ring() ->
    sipserver:get_env(cpl_minimum_ringtime, 10).

%%--------------------------------------------------------------------
%% Function: 
%% Descrip.: 
%% Returns : 
%%--------------------------------------------------------------------
get_server_max() ->
    sipserver:get_env(cpl_call_max_timeout, 120).

%%--------------------------------------------------------------------
%% Function:
%% Descrip.:
%% Returns : {Result, BestLocation, BestResponse}
%%--------------------------------------------------------------------
test_proxy_destinations(_Count, _BranchBase, _Request, _Actions, _Timeout, _Recurse, _STHandler) ->
    BestLocation = none,
    BestResponse = none,
    
    %% Index is used to retrieve process dict data in order
    %% each erase(Index) returns {NodeInTestScript, Result}
    Index = get_next_put(),
    %% io:format("test_backend: Index = ~p get(Index) = ~p~n",[Index, get(Index)]), DDD
    case erase(Index) of
	%% put(Index, {Test, Val})
	{test2_2a, Val} ->
	    {Val, BestLocation, BestResponse};
	{test2_2b, Val} ->
	    {Val, BestLocation, BestResponse};
	{test2_3a, Val} ->
	    {Val, BestLocation, BestResponse};
	{test2_3b, Val} ->
	    {Val, BestLocation, BestResponse};
	{test2_5, redirection} ->
	    %% what 
	    {redirection, sipurl:parse("sip:jones@jonespc.example.com"), BestResponse};
	
	%% put(Index, Val)
	Val ->
	    {Val, BestLocation, BestResponse}
    end.

%% look for the next key - numbered from 1-N
get_next_put() ->
    L = lists:sort(get()),
    [{Index, _} | _] = L,
    Index.

	    




%%====================================================================
%% Behaviour functions
%%====================================================================

%%====================================================================
%% Internal functions
%%====================================================================



