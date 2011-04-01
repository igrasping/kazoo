%%%-------------------------------------------------------------------
%%% @author James Aimonetti <>
%%% @copyright (C) 2011, James Aimonetti
%%% @doc
%%% running timer
%%% @end
%%% Created : 30 Mar 2011 by James Aimonetti <>
%%%-------------------------------------------------------------------
-module(ts_timer).

-behaviour(gen_server).

%% API
-export([start_link/0, start/0, start/1, tick/0, tick/1, stop/0, stop/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

start() ->
    start("Start").
start(Msg) ->
    gen_server:call(?SERVER, {start, Msg}).

tick() ->
    tick("Tick").
tick(Msg) ->
    gen_server:call(?SERVER, {tick, Msg}).

stop() ->
    stop("Stop").

stop(Msg) ->
    gen_server:call(?SERVER, {stop, Msg}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    {ok,dict:new()}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({start, Msg}, {Pid, _}, S) ->
    D = io_lib:format("TS_TIMER(~p): ~p~n", [Pid, Msg]),
    erlang:monitor(process, Pid),
    {reply, ok, dict:store(Pid, {erlang:now(), [D]}, S)};
handle_call({tick, Msg}, {Pid, _}, S) ->
    case dict:find(Pid, S) of
	{ok, {Start, L}} ->
	    {reply, ok, dict:store(Pid, {Start, [io_lib:format("TS_TIMER(~p): At ~10.w micros: ~p~n", [Pid, timer:now_diff(erlang:now(), Start), Msg])
						 | L]}, S)};
	error -> {reply, ok, S}
    end;
handle_call({stop, Msg}, {Pid, _}, S) ->
    case dict:find(Pid, S) of
	{ok, {Start, L}} ->
	    [ io:format(D, []) || D <- lists:reverse(L) ],
	    io:format("TS_TIMER(~p): Stopping ~10.w micros: ~p~n", [Pid, timer:now_diff(erlang:now(), Start), Msg]);
	error -> ok
    end,
    {reply, ok, dict:erase(Pid, S)};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({'DOWN', _, process, Pid, _}, State) ->
    handle_call({stop, "Stop"}, {Pid, ok}, State),
    {noreply, dict:erase(Pid, State)};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
