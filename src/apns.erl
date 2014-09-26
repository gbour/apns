%%%-------------------------------------------------------------------
%%% Author  : kiran khaladkar <kiran.khaladkar@geodesic.com>
%%% Description : apple push notification server
%%%
%%% Created :  28 Jan 2010 by my name <kiran.khaladkar@geodesic.com>
%%%-------------------------------------------------------------------
-module(apns).
-include("apns.hrl").
-behaviour(gen_server).

-define(PRINT, io:format).
-define(NAME(), element(2, erlang:process_info(self(), registered_name))).

%% API
-export([start_link/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).
-export([notify/3, form_payload/6]).
%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Args, Opts) ->
	Name = proplists:get_value(name, Opts, ?MODULE),

	gen_server:start_link({local, Name}, ?MODULE, Args, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the se\"im\":~p}rver
%%--------------------------------------------------------------------
init([Address, Port, Cert, Key]) ->
	%% remove these 2 application starts' later
	application:start(inets),
	application:start(ssl),
	ssl:start(),

	Tid = ets:new(apns_table, [ordered_set]),
	case connect(Cert, Key, Address, Port) of
	{ok, Socket} ->
	    	{ok, #apns_state{address = Address, port = Port, ssl_socket = Socket,ssl_certificate = Cert, ssl_key = Key, session_token_table = Tid}};
	{stop, Reason} ->
		ets:delete(Tid),
		ignore %%So that supervisor ignores the failure of this process
	end.
	
%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
	Reply = ok,
	{reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------

%%this is to notify user status of a perticular account. 
%%	1. If the account is connected 		-->	Status = connected
%%	2. If the account is disconnected 	--> 	Status  = disconnected
handle_cast({notify_service, SessionId, IMType, UserName, Status}, #apns_state{session_token_table = SessionTokenTid, ssl_socket = Socket} = State) ->
	case ets:lookup(SessionTokenTid, erlang:list_to_atom(SessionId)) of 
	[{Session,Token, _}] ->
		?PRINT("~nDEBUG: token found~n~p~n", [{Session, Token}]),
		Payload = case Status of
		connected ->
			?PRINT("~nNotifying login", []),
    			lists:flatten(io_lib:format("{\"aps\":{\"alert\":{\"body\":\"~p connected to ~p\", \"action-loc-key\":null},\"badge\":\"null\",\"sound\":\"default\"}, \"im\":~p, \"login\":~p}",[erlang:list_to_atom(UserName), erlang:list_to_atom(IMType), IMType, UserName]));
		disconnected ->
			?PRINT("~nNotifying logout", []),
    			lists:flatten(io_lib:format("{\"aps\":{\"alert\":{\"body\":\"~p disconnected from ~p\",\"action-loc-key\":null},\"sound\":\"default\"}, \"im\":~p, \"login\":~p}",[erlang:list_to_atom(UserName), erlang:list_to_atom(IMType), IMType, UserName]))
		end,
		erlang:spawn(apns, notify, [Socket, Token, Payload]);
	_Other ->
		ok
	end,
	{noreply, State};

%% this is to notify that the client session has been timed out from our server
handle_cast({notify, SessionId, disconnected}, #apns_state{session_token_table = SessionTokenTid, ssl_socket = Socket} = State) ->
	case ets:lookup(SessionTokenTid, erlang:list_to_atom(SessionId)) of 
	[{Session,Token, _}] ->
		?PRINT("~nDEBUG: token found~n~p~n", [{Session, Token}]),
		Payload = lists:flatten("{\"aps\":{\"alert\":{\"body\":\"Your session has been timed out due to inactivity\", \"action-loc-key\":null},\"badge\":null,\"sound\":\"default\"}}"),
		erlang:spawn(apns, notify, [Socket, Token, Payload]);
	_Other ->
		ok
	end,
	{noreply, State};

handle_cast({notify, SessionId, IMType, {FromUID, FromNick}, To}, #apns_state{session_token_table = SessionTokenTid, ssl_socket = Socket} = State) ->
	?PRINT("~n IN NOTIFY ~n", []),
	case ets:lookup(SessionTokenTid, erlang:list_to_atom(SessionId)) of 
	[{Session,Token, MsgCount}] ->
		?PRINT("~nDEBUG: token found~n~p~n", [{Session, Token, MsgCount}]),
    		Payload = lists:flatten(io_lib:format("{\"aps\":{\"alert\":{\"body\":\"Message received from ~p\",\"action-loc-key\":\"Reply\"},\"badge\":~p,\"sound\":\"default\"},\"name\":~p,\"login\":~p,\"im\":~p}",[erlang:list_to_atom(FromNick), MsgCount+1, FromUID, To, IMType])),
		erlang:spawn(apns, notify, [Socket, Token, Payload]),
		%notify(Socket, Token, Payload),
		ets:insert(SessionTokenTid, {Session, Token, MsgCount+1});
	_Other ->
		ok
	end,
	{noreply, State};

%%Show message in the apns notification
handle_cast({notify, SessionId, IMType, {FromUID, FromNick}, To, Message}, #apns_state{session_token_table = SessionTokenTid, ssl_socket = Socket} = State) -> 
	io:format("~n IN NOTIFY ~n"),
	case ets:lookup(SessionTokenTid, erlang:list_to_atom(SessionId)) of 
	[{Session,Token, MsgCount}] ->
		io:format("~n~n~nDEBUG: token found~n~p~n~n", [{Session, Token, MsgCount, Message}]),
		SimpleMessage = case catch xmerl_scan:string(Message) of
		{'EXIT', _} ->
			Message;
		{XML, _} ->
			%{font,[{color,"#000000"}],["gjhgjhg"]}
			{font, _, Msg} = xmerl_lib:simplify_element(XML),
			lists:flatten(Msg)
		end,
		erlang:spawn(apns, notify, [Socket, Token, form_payload(FromNick, MsgCount+1, FromUID, To, IMType, SimpleMessage)]),
    		%Payload = lists:flatten(io_lib:format("{\"aps\":{\"alert\":{\"body\":\"Message received from ~p\",\"action-loc-key\":\"Reply\"},\"badge\":~p,\"sound\":\"default\"},\"name\":~p,\"login\":~p,\"im\":~p}",[erlang:list_to_atom(FromNick), MsgCount+1, FromUID, To, IMType])),
		%erlang:spawn(apns, notify, [Socket, Token, Payload]),
		%notify(Socket, Token, Payload),
		ets:insert(SessionTokenTid, {Session, Token, MsgCount+1});
	_Other ->
		ok
	end,
	{noreply, State};

handle_cast({raw, DeviceId, Msg}, State=#apns_state{ssl_socket=Socket}) ->
    io:format("generate raw APNS msg: apns ~p~n",[?NAME()]),
    erlang:spawn(apns, notify, [Socket, DeviceId, Msg]),

    {noreply, State};

%%Add a new {session, token} entry in the session_token_table
handle_cast({add_token, SessionId, Token}, #apns_state{session_token_table = SessionTokenTid} = State) ->
	%io:format("~n~n6666666666666666666~nADDING TOKEN~n"),
	ets:insert(SessionTokenTid, {erlang:list_to_atom(SessionId), Token, 0}),
	{noreply, State};

%%this is called once the client starts polling again 
%%this resets the badge which show the no of unread messages by the client.	
handle_cast({reset_token, SessionId}, #apns_state{session_token_table = SessionTokenTid}=State) ->
	case ets:lookup(SessionTokenTid, erlang:list_to_atom(SessionId)) of
	[{_,Token, _}] ->	
		ets:insert(SessionTokenTid, {erlang:list_to_atom(SessionId), Token, 0});
	_Other ->
		?PRINT("[ERROR : token incorrect or not found]", [])
	end,
	{noreply, State};

%%this is called before the SessionId is removed from server, 
%%in short just before the user is totally disconnected from server
handle_cast({remove_token, SessionId}, #apns_state{session_token_table=SessionTokenTid} = State) ->
	case ets:delete(SessionTokenTid, erlang:list_to_atom(SessionId)) of
	true -> ok;
	_Other -> failed
	end,
	{noreply, State};

handle_cast(terminate, #apns_state{session_token_table = SessionTokenTid, ssl_socket = Socket} = State) ->
	ets:delete(SessionTokenTid),
	ssl:close(Socket),
	{stop, apns_terminate, State};

handle_cast(_Msg, State) ->
	?PRINT("~nUnhandled: ~p~n", [_Msg]),
	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(notify_success, State) ->
	?PRINT("Notify successful", []),
	{noreply, State};

handle_info({notify_error, Reason}, State) ->
	?PRINT("Notify error :~p", [Reason]),
	{noreply, State};
	
handle_info({ssl_closed, Socket}, #apns_state{address = Address, port = Port, ssl_certificate = SSL_Cert, ssl_key = SSL_Key} = State) ->
	case reconnect(SSL_Cert, SSL_Key, Address, Port) of
	{ok, Socket} ->
		NewState = State#apns_state{ssl_socket = Socket};
	Other ->
		?PRINT("~nApple apns server cannot be reached because ~p ~n", [Other]),
		gen_server:cast(self(), terminate),
		NewState = State
	end,
	{noreply, NewState};

handle_info({ssl_error, Socket, Reason}, State) ->
	?PRINT("~nDEBUG: SSL ERROR :~p~n", [{Socket, Reason}]),
	{noreply, State};

handle_info(_Info, State) ->
	?PRINT("~nDEBUG: unhandled message ~p~n", [{_Info}]),
     	{noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
     	ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
     	{ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
notify(Socket, Token, Payload) ->
	io:format("~nNOTIFY DEBUG:~p~n", [{Socket, Token, Payload}]),
	TokenI = erlang:list_to_integer(Token, 16),
	TokenBin = <<TokenI:32/integer-unit:8>>,
	PayloadBin = erlang:list_to_binary(Payload),
	PayloadLength = erlang:byte_size(PayloadBin),
    	Packet = <<0:8, 32:16, TokenBin/binary, PayloadLength:16, PayloadBin/binary>>,
	case ssl:send(Socket, Packet) of
	ok ->
		ok; %apns!notify_success;
	{error, Reason} ->
		ok %apns!{notify_error, Reason}
	end.

connect(Cert, Key, Address, Port) ->	
    	%ssl:seed("someseedstring"),
        ssl:start(),
     	Options = [Cert, Key, {mode, binary}],
    	Timeout = 60000,
    	io:format("~nConnecting to apple server", []),
    	case ssl:connect(Address, Port, Options, Timeout) of
	{ok, Soc} ->
	    	io:format("~nConnected ~p~n", [{Soc}]),
		{ok, Soc};
	_Other ->
	    	io:format("~nConnection failed (~p)~n", [_Other]),
				
		{stop, _Other} 
    	end.

reconnect(Cert, Key, Address, Port) ->
	connect(Cert, Key, Address, Port).

form_payload(FromNick, MsgCount, FromUID, To, IMType, Message) ->
	%% "{\"aps\":{\"alert\":{\"body\":\"Message received from ~p\",\"action-loc-key\":\"Reply\"},\"badge\":~p,\"sound\":\"default\"},\"name\":~p,\"login\":~p,\"im\":~p}",
	%%FromNick, MsgCount+1, FromUID, To, IMType	
	io:format("~n5555555555555555555555555555555555~nFormpayload~p~n",[{FromNick, MsgCount, FromUID, To, IMType, Message}]),

	Reply = "\"Reply\"",
	View = "\"View\"",
	Aps = "{\"aps\":{\"alert\":{\"body\":",
	Msg = "\""++FromNick ++ ":" ++ Message++"\",", %% calc this later
	LockKey = "\"action-loc-key\":"++Reply++"},",
	Badge = "\"badge\":"++erlang:integer_to_list(MsgCount)++",",
	Sound = "\"sound\":\"default\"},",
	Name="\"name\":"++"\""++FromUID++"\",",
	Login = "\"login\":"++"\""++To++"\",",
	IM = "\"im\":"++"\""++IMType++"\"}",
	PayLoad = Aps++Msg++LockKey++Badge++Sound++Name++Login++IM,

	Size = erlang:byte_size(erlang:list_to_binary(lists:flatten(PayLoad))),

	if 
		Size < 251 ->
			PayLoad;
		true ->
			ExtraLength = Size -240,
			MsgLength = length(Message),
			%NewMsg = string:sub_string(Message, 0, MsgLength-ExtraLength-3),
			{NewMsg, _} = lists:split(MsgLength-ExtraLength-3, Message),
			TruncMsg = "\""++FromNick ++ ":" ++ string:left(NewMsg, MsgLength - ExtraLength, $.) ++"\",",
			NewLockKey = "\"action-loc-key\":"++View++"},",
			TrucPayLoad = Aps++TruncMsg++NewLockKey++Badge++Sound++Name++Login++IM
	end.
