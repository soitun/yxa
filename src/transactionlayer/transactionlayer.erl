%%%-------------------------------------------------------------------
%%% File    : transactionlayer.erl
%%% Author  : Fredrik Thulin <ft@it.su.se>
%%% Descrip.: Transactionlayer
%%% Created : 05 Feb 2004 by Fredrik Thulin <ft@it.su.se>
%%%-------------------------------------------------------------------
-module(transactionlayer).

-behaviour(gen_server).

%%--------------------------------------------------------------------
%% External exports
%%--------------------------------------------------------------------
-export([
	 start_link/1,
	 send_response_request/3,
	 send_response_request/4,
	 send_response_request/5,
	 transaction_terminating/1,
	 get_handler_for_request/1,
	 get_branch_from_handler/1,
	 start_client_transaction/6,
	 adopt_server_transaction/1,
	 adopt_server_transaction_handler/1,
	 adopt_st_and_get_branchbase/1,
	 send_response_handler/3,
	 send_response_handler/4,
	 send_proxy_response_handler/2,
	 is_good_transaction/1,
	 get_pid_from_handler/1,
	 send_challenge_request/4,
	 send_challenge/4,
	 store_appdata/2,
	 get_my_to_tag/1,
	 debug_show_transactions/0
	]).

%%--------------------------------------------------------------------
%% Transport layer internal exports (functions that should only be
%% invoked from the transport layer).
%%--------------------------------------------------------------------
-export([
	 from_transportlayer/3
	]).

%%--------------------------------------------------------------------
%% Transaction layer internal exports (functions that should only be
%% invoked from the transaction layer).
%%--------------------------------------------------------------------
-export([
	 store_to_tag/2,
	 set_result/2
	]).

%%--------------------------------------------------------------------
%% Internal exports - gen_server callbacks
%%--------------------------------------------------------------------
-export([
	 init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3
	]).

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------
-include("transactionstatelist.hrl").
-include("siprecords.hrl").
-include("sipsocket.hrl").

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------
%% My State
-record(state, {
	 }).

%% A container record to make it clear that all communication with
%% the transaction processes should go through this module.
-record(thandler, {
	  pid
	 }).

%%--------------------------------------------------------------------
%% Macros
%%--------------------------------------------------------------------
%% Wake up every seven seconds to tell expired transactions that it is
%% time to exit
-define(TIMEOUT, 7 * 1000).
-define(STORE_TIMEOUT, 2500).
-define(STATELESS_STORE_TIMEOUT, 1000).

%%====================================================================
%% External functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: start_link(AppModule)
%%           AppModule = atom(), name of Yxa application
%% Descrip.: start the transactionlayer gen_server.
%%           The transactionlayer is only registered localy (on the
%%           current node)
%% Returns : gen_server:start_link/4
%%--------------------------------------------------------------------
start_link(AppModule) ->
    gen_server:start_link({local, transactionlayer}, ?MODULE, [AppModule], []).

%%====================================================================
%% Server functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init([AppModule])
%%           AppModule = atom(), name of Yxa application
%% Descrip.: Initiates the server
%% Returns : {ok, State}          |
%%           {ok, State, Timeout} |
%%           ignore               |
%%           {stop, Reason}
%%--------------------------------------------------------------------
init([AppModule]) ->
    process_flag(trap_exit, true),

    transactionstatelist:empty(), %% create ets tables
    %% Create a tiny ets table to remember some state. Don't use server
    %% process for this since it is bad for parallelism
    Settings = ets:new(transactionlayer_settings, [protected, set, named_table]),
    true = ets:insert_new(Settings, {appmodule, AppModule}),

    %% create statistics ets-entrys
    lists:map(fun(Key) ->
		      true = ets:insert_new(yxa_statistics, {Key, 0})
	      end, [{transactionlayer, transactions}
		   ]),

    logger:log(debug, "Transaction layer started"),
    {ok, #state{}, ?TIMEOUT}.


%%--------------------------------------------------------------------
%% Function: handle_call(Msg, From, State)
%% Descrip.: Handling call messages.
%% Returns : {reply, Reply, State}          |
%%           {reply, Reply, State, Timeout} |
%%           {noreply, State}               |
%%           {noreply, State, Timeout}      |
%%           {stop, Reason, Reply, State}   | (terminate/2 is called)
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------


%%--------------------------------------------------------------------
%% Function: handle_call({monitor_get_transactionlist}, From, State)
%% Descrip.: The stack monitor is requesting our list of transactions.
%% Returns : {reply, {ok, List} State, ?TIMEOUT}
%%           List = transactionstatelist record()
%% Note    : Returning all entrys from an ets table is a relatively
%%           expensive operation. You might not want to run the
%%           stack monitor on a busy system...
%%--------------------------------------------------------------------
handle_call({monitor_get_transactionlist}, _From, State) ->
    {reply, {ok, transactionstatelist:get_all_entries()}, State, ?TIMEOUT};

handle_call(Request, From, State) ->
    logger:log(debug, "Transaction layer: Received unknown gen_server call (from ~p) : ~p", [From, Request]),
    {noreply, State, ?TIMEOUT}.


%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State)
%% Descrip.: Handling cast messages
%% Returns : {noreply, State}          |
%%           {noreply, State, Timeout} |
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: handle_cast({unregister_pid, Pid}, State)
%%           Pid = pid()
%% Descrip.: Delete all transactions handled by Pid from our list.
%%           Does NOT send the Pid any signals to quit or similar -
%%           just removes the transactions from our list.
%% Returns : {noreply, State, ?TIMEOUT}
%%--------------------------------------------------------------------
handle_cast({unregister_pid, Pid}, State) ->
    L = transactionstatelist:get_entrylist_using_pid(Pid),
    {ok, Deleted} = transactionstatelist:delete_using_entrylist(L),
    logger:log(debug, "Transaction layer: Deleted ~p entry(s) from transactionlist upon "
	       "receiving an {unregister_pid, ~p} :~n~p~n(new list is ~p entry(s))",
	       [Deleted, Pid, transactionstatelist:debugfriendly(L),
		transactionstatelist:get_length()]),
    {noreply, State, ?TIMEOUT};

%%--------------------------------------------------------------------
%% Function: handle_cast({debug_show_transactions, FromPid}, State)
%%           Pid = pid()
%% Descrip.: Dump all our current transactions to logger. Just for
%%           debug output.
%% Returns : {noreply, State, ?TIMEOUT}
%%--------------------------------------------------------------------
handle_cast({debug_show_transactions, FromPid}, State) ->
    logger:log(debug, "Transaction layer: Pid ~p asked me to show all ongoing transactions :~n~p",
	       [FromPid, transactionstatelist:debugfriendly()]),
    {noreply, State, ?TIMEOUT};

%%--------------------------------------------------------------------
%% Function: handle_cast({quit}, State)
%% Descrip.: Terminate the transactionlayer process. Should normally
%%           never be used.
%% Returns : {stop, normal, State}
%%--------------------------------------------------------------------
handle_cast({quit}, State) ->
    logger:log(debug, "Transaction layer: Received signal to quit"),
    {stop, normal, State};

handle_cast(Msg, State) ->
    logger:log(debug, "Transaction layer: Received unknown gen_server cast : ~p", [Msg]),
    {noreply, State, ?TIMEOUT}.


%%--------------------------------------------------------------------
%% Function: handle_info(Msg, State)
%% Descrip.: Handling all non call/cast messages
%% Returns : {noreply, State}          |
%%           {noreply, State, Timeout} |
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: handle_info(timeout, State)
%% Descrip.: Wake up and remove all expired transactions from our
%%           list. DOES tell transaction handlers that it is time to
%%           terminate, if they are found to be expired.
%% Returns : {noreply, State, ?TIMEOUT}
%%--------------------------------------------------------------------
handle_info(timeout, State) ->
    case transactionstatelist:get_expired() of
	none ->
	    ok;
	{ok, Expired} when is_list(Expired) ->
	    %% Signal all Expired entrys that they are expired
	    lists:map(fun(#transactionstate{pid = Pid}) when is_pid(Pid) ->
			      logger:log(debug, "Transaction layer: Telling transaction with pid ~p that "
					 "it is expired", [Pid]),
			      gen_server:cast(Pid, {expired})
		      end, Expired)
    end,
    {noreply, State, ?TIMEOUT};

%%--------------------------------------------------------------------
%% Function: handle_info({'EXIT', Pid, Reason}, State)
%%           Pid    = pid()
%%           Reason = normal | term()
%% Descrip.: Trap exit signals from client/server transaction handlers
%%           and act on them. Log if they exit with an error, and
%%           remove them from our list of ongoing transactions.
%% Returns : {noreply, State, ?TIMEOUT}
%%--------------------------------------------------------------------
handle_info({'EXIT', Pid, Reason}, State) ->
    case Reason of
	normal -> logger:log(debug, "Transaction layer: Received normal exit-signal from process ~p", [Pid]);
	_ -> logger:log(error, "Transaction layer: =ERROR REPORT==== Received non-normal exit signal from process ~p :~n~p", [Pid, Reason])
    end,
    case transactionstatelist:get_entrylist_using_pid(Pid) of
	none ->
	    logger:log(debug, "Transaction layer: Received exit signal from ~p not in my list.", [Pid]),
	    true;
	L when is_list(L) ->
	    {ok, Deleted} = transactionstatelist:delete_using_entrylist(L),
	    logger:log(debug, "Transaction layer: Deleted ~p entry(s) from transactionlist :~n~p~n"
		       "(new list is ~p entry(s))", [Deleted, transactionstatelist:debugfriendly(L),
						     transactionstatelist:get_length()]),
	    true
    end,
    {noreply, State, ?TIMEOUT};

handle_info(Msg, State) ->
    logger:log(error, "Transaction layer: Received unknown gen_server info :~n~p", [Msg]),
    {noreply, State, ?TIMEOUT}.

%%--------------------------------------------------------------------
%% Function: terminate/2
%% Descrip.: Shutdown the server
%% Returns : any (ignored by gen_server)
%%--------------------------------------------------------------------
terminate(normal, _State) ->
    logger:log(debug, "Transaction layer: Terminating normally."),
    ok;
terminate(shutdown, _State) ->
    logger:log(debug, "Transaction layer: Shutting down."),
    shutdown;
terminate(Reason, _State) ->
    logger:log(error, "Transaction layer: =ERROR REPORT==== from transactionlayer :~n~p",
	       [Reason]),
    ok.

%%--------------------------------------------------------------------
%% Function: code_change(OldVsn, State, Extra)
%% Purpose : Convert process state when code is changed
%% Returns : {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: received_new_request(Request, Socket, LogStr, AppModule)
%%           Request   = request record()
%%           Socket    = sipsocket record(), the socket this request
%%                                           was received on
%%           LogStr    = string(), describes the request
%%           AppModule = atom(), Yxa application module
%% Descrip.: Act on a new request that has just been delivered to the
%%           transaction layer from the transport layer, where the
%%           transaction layer did not have any prior transaction.
%%           This code executes in the request handler process - NOT
%%           in the transactionlayer. This is to achieve better
%%           concurrency by not doing alot of work in the
%%           transactionlayer process.
%% Returns : {pass_to_core, AppModule} |
%%           continue
%%
%% Notes   :
%%           Meaning of Reply :
%%           continue means that the transaction layer has taken care
%%           of this Request and no further action should be taken by
%%           the caller of this function.
%%
%%           {pass_to_core, AppModule} means that the caller should
%%           apply() AppModule:request/3 with this Request as argument.
%%           We can't do it here since we can't block the
%%           transacton_layer process, and asking the caller to do it
%%           saves us a spawn(). AppModule is the module name passed to
%%           our init/1.
%%
%%
%%           It might be worthwile to insert a dummy-entry in the
%%           transaction layers list of transactions for this new
%%           transaction, before spawning a servertransaction. That
%%           would reduce the workload of a really loaded system that
%%           receives a big percentage of resends before it has had
%%           time to spawn servertransactions that have registered
%%           themselves in the transaction layers list.
%%--------------------------------------------------------------------

%%
%% ACK
%%
received_new_request(#request{method="ACK"}=Request, _Socket, _LogStr, AppModule) ->
    logger:log(debug, "Transaction layer: Received ACK ~s that does not match any existing transaction, passing to core.",
	       [sipurl:print(Request#request.uri)]),
    {pass_to_core, AppModule};

received_new_request(Request, Socket, LogStr, AppModule) when is_record(Request, request) ->
    logger:log(debug, "Transaction layer: No state for received request, starting new transaction"),
    case servertransaction:start_link(Request, Socket, LogStr) of
	{ok, STPid} when is_pid(STPid) ->
	    %% returns true if it is a CANCEL and we find a transaction to cancel, otherwise false
	    case cancel_corresponding_transaction(Request, STPid) of
		true ->
		    logger:log(debug, "Transaction layer: Telling SIP message handler to start this applications "
			       "request function."),
		    {pass_to_core, AppModule};
		false ->
		    continue
	    end;
	{error, resend} ->
	    logger:log(debug, "Transaction layer: Failed starting server transaction (was a resend) - "
		       "ignoring request"),
	    continue;
	E ->
	    %%% XXX erlang:exit() here so that we might return a 500 response (statelessly)?
	    logger:log(error, "Transaction layer: Failed starting server transaction (~p) - ignoring request", [E]),
	    continue
    end.

%%--------------------------------------------------------------------
%% Function: cancel_corresponding_transaction(Request, STPid)
%%           Request = request record()
%%           STPid   = pid of CANCEL server transaction.
%% Descrip.: Part of received_new_request/4. We have received a CANCEL
%%           and here we try to find the corresponding INVITE and tell
%%           it that it has been cancelled. If we find an INVITE, we
%%           return 'false' to _not_ pass this CANCEL to the
%%           Transaction User (core). If we do not find it however, we
%%           return 'true' to pass the CANCEL to core.
%% Returns : PassToCore
%%           PassToCore = true | false
%%--------------------------------------------------------------------
cancel_corresponding_transaction(#request{method="CANCEL"}=Request, STPid) when is_pid(STPid) ->
    Header = Request#request.header,
    %% XXX not only INVITE can be cancelled, RFC3261 9.2 says we should find the
    %% transaction that is being handled by 'assuming the method is anything but
    %% CANCEL or ACK'.
    {CSeqNum, _} = sipheader:cseq(Header),
    %% When looking for the corresponding INVITE transaction, we have to change the
    %% CSeq method of this header to INVITE, in case we received it from a RFC2543 client
    %% (RFC2543 backwards-compatible transaction matching includes the whole CSeq, this is
    %% probably an error in RFC3261 #9.2 that refers to #17.2.3 which does not say that
    %% CANCEL matches a transaction even though the CSeq method differs)
    IHeader = keylist:set("CSeq", [sipheader:cseq_print({CSeqNum, "INVITE"})], Header),
    Invite = Request#request{method="INVITE", header=IHeader},
    case get_server_transaction_pid(Invite) of
	InvitePid when is_pid(InvitePid) ->
	    logger:log(debug, "Transaction layer: CANCEL matches server transaction handled by ~p", [InvitePid]),
	    {Status, Reason} =
		case util:safe_is_process_alive(InvitePid) of
		    {true, _} ->
			logger:log(debug, "Transaction layer: Cancelling original request handled by ~p "
				   "and responding 200 Ok", [InvitePid]),
			%% RFC3326 #2 says we SHOULD include any present Reason header in a CANCEL we
			%% receive in the CANCELs we generate based on it
			ExtraHeaders = [{"Reason",
					 keylist:fetch('reason', Header)
					}],
			gen_server:cast(InvitePid, {cancelled, ExtraHeaders}),
			{200, "Ok"};
		    {false, _} ->
			logger:log(debug, "Transaction layer: Transaction to be cancelled handled by dead "
				   "pid '~p', responding 481 Call/Transaction Does Not Exist", [InvitePid]),
			{481, "Call/Transaction Does Not Exist"}
		end,
	    gen_server:cast(STPid, {create_response, Status, Reason, [], <<>>}),
	    %% Don't pass to core
	    false;
	none ->
	    logger:log(debug, "Transaction layer: Could not find transaction to cancel, "
		       "pass it on to TU/proxy core."),
	    %% Pass to core
	    true
    end;
cancel_corresponding_transaction(Request, STPid) when is_record(Request, request), is_pid(STPid) ->
    %% Request method not CANCEL, pass to core
    true.

%%--------------------------------------------------------------------
%% Function: get_server_transaction(R)
%%           R           = request record() | response record()
%% Descrip.: Find a server transaction in our list given either a
%%           request or a response record().
%% Returns : THandler |
%%           error    |
%%           none
%%           THandler    = transactionstate record()
%%--------------------------------------------------------------------
get_server_transaction(Request) when is_record(Request, request) ->
    transactionstatelist:get_server_transaction_using_request(Request);
get_server_transaction(Response) when is_record(Response, response) ->
    transactionstatelist:get_server_transaction_using_response(Response).

%%--------------------------------------------------------------------
%% Function: get_server_transaction_pid(R)
%%           R           = request record() | response record()
%% Descrip.: Find a server transaction given either a request or a
%%           response record(). Return it's pid.
%% Returns : Pid |
%%           none
%%           Pid         = pid()
%%--------------------------------------------------------------------
get_server_transaction_pid(Re) when is_record(Re, request); is_record(Re, response) ->
    case get_server_transaction(Re) of
	none ->
	    none;
	TState when is_record(TState, transactionstate) ->
	    case transactionstatelist:extract([pid], TState) of
		[TPid] when is_pid(TPid) ->
		    TPid;
		_ ->
		    none
	    end
    end.

%%--------------------------------------------------------------------
%% Function: get_client_transaction(Response)
%%           Response    = response record()
%% Descrip.: Find a client transaction given a response.
%% Returns : TState |
%%           none
%%           TState      = transactionstate record()
%%--------------------------------------------------------------------
get_client_transaction(Response) when is_record(Response, response) ->
    Header = Response#response.header,
    TopVia = sipheader:topvia(Header),
    Branch = sipheader:get_via_branch(TopVia),
    {_, Method} = sipheader:cseq(Header),
    transactionstatelist:get_client_transaction(Method, Branch).

%%--------------------------------------------------------------------
%% Function: get_client_transaction_pid(Response)
%%           Response    = response record()
%% Descrip.: Find a client transaction given a response.
%%           Return it's pid.
%% Returns : Pid  |
%%           none
%%           Pid         = pid()
%%--------------------------------------------------------------------
get_client_transaction_pid(Response) when is_record(Response, response) ->
    case get_client_transaction(Response) of
	none ->
	    none;
	TState when is_record(TState, transactionstate) ->
	    case transactionstatelist:extract([pid], TState) of
		[TPid] when is_pid(TPid) ->
		    TPid;
		_ ->
		    none
	    end
    end.


%%--------------------------------------------------------------------
%%% Interface functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: send_response_request(Request, Status, Reason,
%%                                 ExtraHeaders, RBody)
%%           Request      = request record()
%%           Status       = integer(), SIP status code
%%           Reason       = string(), SIP reason phrase
%%           ExtraHeaders = keylist record()
%%           RBody        = string(), response body
%% Descrip.: Locate the server transaction handler using a request,
%%           and then ask the server transaction handler to send a
%%           response.
%% Returns : none  |
%%           ok    |
%%           {error, E}
%%           E = string(), describes the error
%%
%% Note    : If this function returns 'none' it did not find a server
%%           transasction. Should probably be changed to
%%           {error, "No server transaction found"} or similar.
%%--------------------------------------------------------------------
send_response_request(Request, Status, Reason) when is_record(Request, request) ->
    send_response_request(Request, Status, Reason, []).

send_response_request(Request, Status, Reason, ExtraHeaders) when is_record(Request, request) ->
    send_response_request(Request, Status, Reason, ExtraHeaders, <<>>).

send_response_request(Request, Status, Reason, ExtraHeaders, RBody) when is_record(Request, request) ->
    {Method, URI} = {Request#request.method, Request#request.uri},
    case get_handler_for_request(Request) of
	{error, E} ->
	    logger:log(error, "Transaction layer: Failed locating server transaction handler for request ~s ~s : ~p",
		       [Method, sipurl:print(URI), E]),
	    none;
	none ->
	    logger:log(error, "Transaction layer: No server transaction found for request ~s ~s",
		       [Method, sipurl:print(URI)]),
	    none;
	TH when is_record(TH, thandler) ->
	    logger:log(debug, "Transaction layer: Located server transaction handler ~p", [TH#thandler.pid]),
	    send_response_handler(TH, Status, Reason, ExtraHeaders, RBody)
    end.

%%--------------------------------------------------------------------
%% Function: send_response_handler(TH, Status, Reason, ExtraHeaders,
%%                                 RBody)
%%           TH           = thandler record(), transaction handler
%%           Request      = request record()
%%           Status       = integer(), SIP status code
%%           Reason       = string(), SIP reason phrase
%%           ExtraHeaders = keylist record()
%%           RBody        = string(), response body
%% Descrip.: Ask a server transaction handler to send a response.
%% Returns : ok    |
%%           {error, E}
%%           E = string(), describes the error
%%--------------------------------------------------------------------
send_response_handler(TH, Status, Reason) when is_record(TH, thandler) ->
    send_response_handler(TH, Status, Reason, []).

send_response_handler(TH, Status, Reason, ExtraHeaders) when is_record(TH, thandler) ->
    send_response_handler(TH, Status, Reason, ExtraHeaders, <<>>).

send_response_handler(TH, Status, Reason, ExtraHeaders, RBody)
  when is_record(TH, thandler), is_integer(Status), is_list(Reason), is_list(ExtraHeaders), is_binary(RBody) ->
    case catch gen_server:cast(TH#thandler.pid, {create_response, Status, Reason, ExtraHeaders, RBody}) of
	ok ->
	    ok;
	_ ->
	    {error, "Transaction handler failure"}
    end.

%%--------------------------------------------------------------------
%% Function: send_proxy_response_handler(TH, Response)
%%           TH           = thandler record(), transaction handler
%%           Response     = response record()
%% Descrip.: Ask a server transaction handler to proxy a response.
%%           When we proxy (as opposed to send) a response, we do some
%%           additional processing like removing the top Via header.
%% Returns : ok    |
%%           {error, E}
%%           E = string(), describes the error
%%--------------------------------------------------------------------
send_proxy_response_handler(TH, Response) when is_record(TH, thandler), is_record(Response, response) ->
    case gen_server:cast(TH#thandler.pid, {forwardresponse, Response}) of
	ok ->
	    ok;
	_ ->
	    {error, "Transaction handler failure"}
    end.

%%--------------------------------------------------------------------
%% Function: get_handler_for_request(Request)
%%           Request = request record()
%% Descrip.: Return the server transaction handler using a request.
%%           This is the ordinary way for an application to locate the
%%           server transaction for a request it gets passed, in order
%%           to send a response or get it's branch or whatever.
%% Returns : THandler   |
%%           {error, E}
%%           THandler = thandler record()
%%           E = string(), describes the error
%%--------------------------------------------------------------------
get_handler_for_request(Request) ->
    case get_server_transaction_pid(Request) of
        none ->
            {error, "No state found"};
        TPid when is_pid(TPid) ->
            #thandler{pid=TPid}
    end.

%%--------------------------------------------------------------------
%% Function: adopt_server_transaction(Request)
%%           Request = request record()
%% Descrip.: Adopt a server transaction. Adoption means that the
%%           server transaction will inform whoever is adopting it
%%           if the server transaction gets cancelled, and when it
%%           terminates.
%% Returns : THandler         |
%%           {ignore, Reason} |
%%           {error, E}
%%           THandler = thandler record()
%%           Reason   = cancelled | completed
%%           E        = string(), describes the error
%%--------------------------------------------------------------------
adopt_server_transaction(Request) when is_record(Request, request) ->
    case get_handler_for_request(Request) of
	TH when is_record(TH, thandler) ->
	    adopt_server_transaction_handler(TH);
	_ ->
	    {error, "unknown result from get_handler_for_request"}
    end.

%% See adopt_server_transaction/1 above
adopt_server_transaction_handler(TH) when is_record(TH, thandler) ->
    case catch gen_server:call(TH#thandler.pid, {set_report_to, self()}, ?STORE_TIMEOUT) of
	{ignore, Reason} ->
	    {ignore, Reason};
	ok ->
	    TH;
	{error, E} ->
	    {error, E};
	_ ->
	    {error, "Server transaction handler failed"}
    end.

%%--------------------------------------------------------------------
%% Function: adopt_st_and_get_branchbase(TH)
%% Function: adopt_st_and_get_branchbase(Request)
%%           TH      = thandler record()
%%           Request = request record()
%% Descrip.: Adopt a server transaction, and get it's branch. This is
%%           just a helper function for applications, since this is
%%           typically what they do anyways. If you want to know for
%%           example the real reason it returns 'ignore', use the more
%%           articulate adopt_server_transaction_handler/1.
%% Returns : BranchBase |
%%           error      |
%%           ignore
%%           BranchBase = string(), the server transactions branch,
%%                        minus the "-UAS" suffix
%%--------------------------------------------------------------------
adopt_st_and_get_branchbase(Request) when is_record(Request, request) ->
    case get_handler_for_request(Request) of
	TH when is_record(TH, thandler) ->
	    adopt_st_and_get_branchbase(TH);
	{error, Reason} ->
	    logger:log(error, "Transaction layer: Could not find transaction handler for request : ~p",
		       [Reason]),
	    error
    end;
adopt_st_and_get_branchbase(TH) when is_record(TH, thandler) ->
    case adopt_server_transaction_handler(TH) of
	{ignore, _Reason} ->
	    ignore;
	{error, E} ->
	    logger:log(error, "Transaction layer: Could not adopt server transaction handler ~p : ~p", [TH, E]),
	    error;
	TH ->
	    case get_branch_from_handler(TH) of
		error ->
		    error;
		Branch when is_list(Branch) ->
		    case string:rstr(Branch, "-UAS") of
			0 ->
			    {ok, TH, Branch};
			Index when is_integer(Index) ->
			    BranchBase = string:substr(Branch, 1, Index - 1),
			    {ok, TH, BranchBase}
		    end
	    end
    end.

%%--------------------------------------------------------------------
%% Function: get_branch_from_handler(TH)
%%           TH = thandler record(), the transaction handler to query
%% Descrip.: Get the branch from a server transaction. It is useful to
%%           get the branch from a server transaction for use in
%%           logging, and when generating branches for client
%%           transactions related to the server transaction.
%% Returns : Branch |
%%           error
%%           Branch = string()
%%--------------------------------------------------------------------
get_branch_from_handler(TH) when is_record(TH, thandler) ->
    TPid = TH#thandler.pid,
    case catch gen_server:call(TPid, {get_branch}, ?STORE_TIMEOUT) of
	{ok, Branch} ->
	    Branch;
	Unknown ->
	    logger:log(error, "Transaction layer: Failed getting branch from pid ~p : ~p", [TPid, Unknown]),
	    error
    end.

%% unused
transaction_terminating(TransactionPid) ->
    gen_server:cast(transactionlayer, {unregister_pid, TransactionPid}),
    ok.

%%--------------------------------------------------------------------
%% Function: start_client_transaction(Request, SocketIn, Dst, Branch,
%%                                    Timeout, ReportTo)
%%           Request  = request record()
%%           SocketIn = sipsocket record(), XXX which socket is this?
%%           Dst      = sipdst record(), the destination for this
%%                      client transaction
%%           Branch   = string(), branch parameter to use
%%           Timeout  = integer(), timeout for INVITE transactions
%%                                 (seconds from now)
%%           ReportTo = pid(), who the client transaction should
%%                      report to
%% Descrip.: Start a new client transaction.
%% Returns : Pid        |
%%           {error, E}
%%           Pid = pid()
%%           E   = string()
%%--------------------------------------------------------------------
start_client_transaction(Request, SocketIn, Dst, Branch, Timeout, ReportTo)
  when is_record(Request, request), is_record(Dst, sipdst), is_list(Branch), is_integer(Timeout),
       is_pid(ReportTo); ReportTo == none ->
    case clienttransaction:start_link(Request, SocketIn, Dst, Branch, Timeout, ReportTo) of
	{ok, CPid} ->
	    CPid;
	E ->
	    logger:log(error, "Transaction layer: Failed starting client transaction : ~p", [E]),
	    {error, "Failed starting client transaction"}
    end.

%%--------------------------------------------------------------------
%% Function: store_to_tag(Request, ToTag)
%%           Request  = request record()
%%           ToTag    = string()
%% Descrip.: Store the to-tag we use when sending non-2xx responses in
%%           INVITE server transactions. We need to do this to
%%           correctly match ACK to the server transaction.
%% Returns : ok         |
%%           {error, E}
%%           E = string(), description of error
%%--------------------------------------------------------------------
store_to_tag(Request, ToTag) when is_record(Request, request), is_list(ToTag) ->
    case get_server_transaction(Request) of
	none ->
	    {error, "Transaction not found"};
	ThisState when is_record(ThisState, transactionstate) ->
	    NewTState = transactionstatelist:set_response_to_tag(ThisState, ToTag),
	    ok = transactionstatelist:update_transactionstate(NewTState),
	    ok
    end.

%%--------------------------------------------------------------------
%% Function: set_result(Request, ToTag)
%%           Request  = request record()
%%           ToTag    = string()
%% Descrip.: Set the informational result parameter of a transaction.
%%           This 'result' value is only used for debugging/
%%           informational purposes.
%% Returns : ok         |
%%           {error, E}
%%           E = string(), description of error
%%--------------------------------------------------------------------
set_result(Request, Value) when is_record(Request, request), is_list(Value) ->
    case get_server_transaction(Request) of
	none ->
	    {error, "Transaction not found"};
	ThisState when is_record(ThisState, transactionstate) ->
	    NewTState = transactionstatelist:set_result(ThisState, Value),
	    ok = transactionstatelist:update_transactionstate(NewTState),
	    ok
    end.

%%--------------------------------------------------------------------
%% Function: store_appdata(Request, ToTag)
%%           Request  = request record()
%%           Value    = term()
%% Descrip.: Store some arbitrary data associated with this
%%           transcation for an application. The Yxa stack never uses
%%           this data - it is just provided as convenient storage
%%           for application writers.
%% Returns : ok         |
%%           {error, E}
%%           E = string(), description of error
%%--------------------------------------------------------------------
store_appdata(Request, Value) when is_record(Request, request) ->
    case get_server_transaction(Request) of
	none ->
	    {error, "Transaction not found"};
	ThisState when is_record(ThisState, transactionstate) ->
	    NewTState = transactionstatelist:set_appdata(ThisState, Value),
	    ok = transactionstatelist:update_transactionstate(NewTState),
	    ok
    end.

%%--------------------------------------------------------------------
%% Function: is_good_transaction(TH)
%%           TH = thandler record() | term()
%% Descrip.: Check if a given argument is a thandler record() that
%%           refers to a transaction handler that is still alive.
%% Returns : true  |
%%           false
%%--------------------------------------------------------------------
is_good_transaction(TH) when is_record(TH, thandler) ->
    case util:safe_is_process_alive(TH#thandler.pid) of
	{true, _} ->
	    true;
	_ ->
	    false
    end;
is_good_transaction(_) ->
    false.

%%--------------------------------------------------------------------
%% Function: get_pid_from_handler(TH)
%%           TH      = thandler record() | term()
%% Descrip.: Sometimes it is actually necessary for something besides
%%           the transaction layer to know the pid handling a
%%           transaction. In those cases, this function lets a caller
%%           extract the pid of a transaction handler. Note though
%%           that you should NEVER communicate with that pid directly.
%% Returns : Pid  |
%%           none
%%           Pid = pid()
%%--------------------------------------------------------------------
get_pid_from_handler(TH) when is_record(TH, thandler) ->
    TH#thandler.pid;
get_pid_from_handler(_) ->
    none.

%%--------------------------------------------------------------------
%% Function: send_challenge_request(Request, Type, Stale, RetryAfter)
%%           Request    = request record()
%%           Type       = www | proxy
%%           Stale      = true | false
%%           RetryAfter = integer()
%% Descrip.: Locate a server transaction handler using Request, then
%%           invoke send_challenge() with the rest of our parameters.
%% Returns : ok         |
%%           {error, E}
%%           E = string()
%%--------------------------------------------------------------------
send_challenge_request(Request, Type, Stale, RetryAfter) ->
    case get_handler_for_request(Request) of
	TH when is_record(TH, thandler) ->
	    send_challenge(TH, Type, Stale, RetryAfter);
	_ ->
	    {error, "Could not locate handler for request"}
    end.

%%--------------------------------------------------------------------
%% Function: send_challenge(TH, Type, Stale, RetryAfter)
%%           TH         = thandler record()
%%           Type       = www | proxy
%%           Stale      = true | false
%%           RetryAfter = integer()
%% Descrip.: Generate a '407 Proxy-Authenticate' or
%%           '401 WWW-Authenticate' response and hand this to a
%%           server transaction handler. If given a request record()
%%           as In, first locate the real server transaction handler.
%% Returns : ok
%%--------------------------------------------------------------------
send_challenge(TH, www, Stale, RetryAfter) when is_record(TH, thandler) ->
    AuthHeader = [{"WWW-Authenticate", sipheader:auth_print(sipauth:get_challenge(), Stale)}],
    send_challenge2(TH, 401, "Authentication Required", AuthHeader, RetryAfter);
send_challenge(TH, proxy, Stale, RetryAfter) when is_record(TH, thandler) ->
    AuthHeader = [{"Proxy-Authenticate", sipheader:auth_print(sipauth:get_challenge(), Stale)}],
    send_challenge2(TH, 407, "Proxy Authentication Required", AuthHeader, RetryAfter).

send_challenge2(TH, Status, Reason, AuthHeader, RetryAfter) when is_record(TH, thandler)->
    RetryHeader = case RetryAfter of
		      I when is_integer(I) ->
			  [{"Retry-After", [integer_to_list(RetryAfter)]}];
		      _ ->
			  []
		  end,
    ExtraHeaders = lists:append(AuthHeader, RetryHeader),
    send_response_handler(TH, Status, Reason, ExtraHeaders),
    case yxa_config:get_env(stateless_challenges) of
	{ok, true} ->
	    %% Adhere to advice in RFC3261 #26.3.2.4 (DoS Protection) saying we SHOULD terminate
	    %% the server transaction immediately after sending a challenge, to preserve server
	    %% resources but also to not resend these and thus be more usefull to someone using
	    %% us to perform a DoS on a third party.
	    %%
	    %% Default is to NOT do this, since we will have sent a 100 Trying in response to
	    %% an INVITE (and the DoS thingy only applies to INVITE transactions, since we wouldn't
	    %% send a 401/407 response to a non-INVITE reliably), and if it is a legitimate INVITE
	    %% and the client receives the 100 but this 401/407 is lost then we have screwed up
	    %% badly. The client would wait until it times out, instead of resubmitting the request.
	    gen_server:cast(TH#thandler.pid, {quit}),
	    ok;
	{ok, false} ->
	    true
    end,
    ok.

%%--------------------------------------------------------------------
%% Function: debug_show_transactions()
%% Descrip.: Make the transaction layer log info about all it's
%%           transactions to the debug log.
%% Returns : ok
%%--------------------------------------------------------------------
debug_show_transactions() ->
    gen_server:cast(transactionlayer, {debug_show_transactions, self()}),
    ok.

%%--------------------------------------------------------------------
%% Function: from_transportlayer(Request, Origin, LogStr)
%%           Request = request record()
%%           Origin  = siporigin record()
%%           LogStr  = string()
%% Descrip.: The transport layer passes us a request it has just
%%           received.
%% Returns : {pass_to_core, AppModule} |
%%           continue
%%           AppModule = atom(), Yxa application module name
%%--------------------------------------------------------------------
from_transportlayer(Request, Origin, LogStr) when is_record(Request, request),
						  is_record(Origin, siporigin),
						  is_list(LogStr) ->
    case get_server_transaction_pid(Request) of
	none ->
	    [{appmodule, AppModule}] = ets:lookup(transactionlayer_settings, appmodule),
	    received_new_request(Request, Origin#siporigin.sipsocket, LogStr, AppModule);
	STPid when is_pid(STPid) ->
	    gen_server:cast(STPid, {siprequest, Request, Origin}),
	    continue
    end;

%%--------------------------------------------------------------------
%% Function: from_transportlayer(Response, Origin, LogStr)
%%           Response = response record()
%%           Origin   = siporigin record()
%%           LogStr   = string()
%% Descrip.: The transport layer passes us a response it has just
%%           received.
%% Returns : {pass_to_core, AppModule} |
%%           continue
%%           AppModule = atom(), Yxa application module name
%%--------------------------------------------------------------------
from_transportlayer(Response, Origin, LogStr) when is_record(Response, response),
						   is_record(Origin, siporigin),
						   is_list(LogStr) ->
    case get_client_transaction_pid(Response) of
	none ->
	    [{appmodule, AppModule}] = ets:lookup(transactionlayer_settings, appmodule),
	    logger:log(debug, "Transaction layer: No state for received response '~p ~s', passing to ~p:response(...).",
		       [Response#response.status, Response#response.reason, AppModule]),
	    {pass_to_core, AppModule};
	CTPid when is_pid(CTPid) ->
	    logger:log(debug, "Transaction layer: Passing response '~p ~s' to registered handler ~p",
		       [Response#response.status, Response#response.reason, CTPid]),
	    gen_server:cast(CTPid, {sipmessage, Response, Origin, LogStr}),
	    continue
    end.

%%--------------------------------------------------------------------
%% Function: get_my_to_tag(TH)
%%           TH = thandler record(), server transaction handle
%% Descrip.: Get to tag that will we used in server transaction response
%% Returns : {ok, ToTag}
%%           ToTag = string()
%%--------------------------------------------------------------------
get_my_to_tag(TH) when is_record(TH, thandler) ->
    gen_server:call(TH#thandler.pid, get_my_to_tag, ?STORE_TIMEOUT).