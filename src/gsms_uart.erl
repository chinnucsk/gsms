%%%---- BEGIN COPYRIGHT --------------------------------------------------------
%%%
%%% Copyright (C) 2007 - 2012, Rogvall Invest AB, <tony@rogvall.se>
%%%
%%% This software is licensed as described in the file COPYRIGHT, which
%%% you should have received as part of this distribution. The terms
%%% are also available at http://www.rogvall.se/docs/copyright.txt.
%%%
%%% You may opt to use, copy, modify, merge, publish, distribute and/or sell
%%% copies of the Software, and permit persons to whom the Software is
%%% furnished to do so, under the terms of the COPYRIGHT file.
%%%
%%% This software is distributed on an "AS IS" basis, WITHOUT WARRANTY OF ANY
%%% KIND, either express or implied.
%%%
%%%---- END COPYRIGHT ----------------------------------------------------------
%%%-------------------------------------------------------------------
%%% @author Tony Rogvall <tony@rogvall.se>
%%% @author Malotte Westman Lönne <malotte@malotte.net>
%%% @copyright (C) 2012, Tony Rogvall
%%% @doc
%%%     SMS command driver.
%%%
%%% Created :  1 Jul 2010 by Tony Rogvall 
%%% @end
%%%-------------------------------------------------------------------
-module(gsms_uart).

-behaviour(gen_server).

-include_lib("lager/include/log.hrl").

%% API
-export([start_link/1, 
	 stop/1,
	 subscribe/1,
	 subscribe/2,
	 unsubscribe/2,
	 setopts/2,
	 at/2, ats/2, atd/2]).

%% Option processing
-export([options/0,
	 split_opts/2,
	 normalise_opts/1,
	 validate_opts/1,
	 validate_opt/2]).

-export([trimhd/1,trimtl/1,trim/1]).

%% gen_server callbacks
-export([init/1, 
	 handle_call/3, 
	 handle_cast/2, 
	 handle_info/2,
	 terminate/2, 
	 code_change/3]).

-define(SERVER, ?MODULE). 
-define(UART_DEFAULT_OPTS,
	[{baud,115200},{mode,list},{active,true},
	 {packet,line},{csize,8},{parity,none},{stopb,1}]).
-define(CTRL_Z, 16#1A).
-define(ESC,    16#1B).

%% For dialyzer
-type gsms_uart_option() :: device | reopen_timeout | reply_timeout.

-type gsms_uart_config() ::
	{device, string()} |
	{reopen_timeout, timeout()} |
	{reply_timeout, timeout()} |
	{smsc, string()}.

-record(subscription,
	{
	  pid,
	  mon,
	  pattern
	}).

-record(ctx,
	{
	  uart,           %% serial port descriptor
	  device,         %% device string
	  caller,         %% parent pid
	  uopts=[],       %% uart options
 	  opts=[],        %% sms options
	  command="",     %% last command
	  reply=[],       %% list of reply line data
	  activity=none,  %% |at,ats,atd
	  client,         %% last client
	  queue,          %% request queue
	  reply_timer,    %% timeout waiting for reply
	  reopen_timer,   %% timer ref
	  subs = []       %% #subscription{}
	}).

%%%===================================================================
%%% API
%%%===================================================================

-spec options() -> [uart:uart_option()|gsms_uart_option()].

options() ->
    uart:options() ++
	[
	 smsc,
	 reopen_timeout,
	 reply_timeout
	].

%%--------------------------------------------------------------------
%% @doc
%% Starts the server.
%%
%% Device contains the path to the Device. <br/>
%% reopen_timeout =/= 0 means that if the driver fails to open the device it
%% will try again in Timeout milliseconds.<br/>
%%
%% @end
%%--------------------------------------------------------------------
-spec start_link([gsms_uart_config()]) -> 
			{ok, Pid::pid()} | 
			ignore | 
			{error, Error::term()}.
%%
%% HUAWEI: uses device /dev/tty.HUAWEIMobile-Pcui
%% for SMS services to be able to get notifications which are
%% NOT available on /dev/tty.HUAWEIMobile-Modem
%%
start_link(Opts) ->
    lager:info("~p: start_link: args = ~p\n", [?MODULE, Opts]),
    gen_server:start_link(?MODULE, [self(),Opts], []).

%%--------------------------------------------------------------------
%% @doc
%% Stops the server.
%%
%% @end
%%--------------------------------------------------------------------
-spec stop(Drv::pid()) -> ok | {error, Error::term()}.

stop(Drv) ->
    gen_server:call(Drv, stop).


%%--------------------------------------------------------------------
%% @doc
%% Subscribe to sms events.
%%
%% @end
%%--------------------------------------------------------------------
-spec subscribe(Drv::pid()) -> {ok,reference()} | {error, Error::term()}.

subscribe(Drv) ->
    subscribe(Drv, []).

%%--------------------------------------------------------------------
%% @doc
%% Subscribe to sms events.
%%
%% @end
%%--------------------------------------------------------------------
-spec subscribe(Drv::pid(),Pattern::[{atom(),string()}]) ->
		       {ok,reference()} | {error, Error::term()}.
subscribe(Drv,Pattern) ->
    gen_server:call(Drv, {subscribe,self(),Pattern}).

%%--------------------------------------------------------------------
%% @doc
%% Unsubscribe from sms events.
%%
%% @end
%%--------------------------------------------------------------------
-spec unsubscribe(Drv::pid(),Ref::reference()) -> ok | {error, Error::term()}.
unsubscribe(Drv,Ref) ->
    gen_server:call(Drv, {unsubscribe,Ref}).

%%--------------------------------------------------------------------
%% @doc
%% Set various options from uart options to smsc options
%%
%% @end
%%--------------------------------------------------------------------

setopts(Drv,Opts) when is_list(Opts) ->
    gen_server:call(Drv, {setopts, Opts}).

%%--------------------------------------------------------------------
%% @doc
%% Run a raw command
%%
%% @end
%%--------------------------------------------------------------------

%% normal at command
at(Drv,Command) ->
    gen_server:call(Drv, {at,Command}).

%% at command that could lead to data-enter state
ats(Drv,Command) ->
    gen_server:call(Drv, {ats,Command}, 20000).

%% send data in data-enter state
atd(Drv, Hex) ->
    gen_server:call(Drv, {atd,Hex}, 20000).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
%%--------------------------------------------------------------------
%% @doc
%% Initializes the server
%%
%% @end
%%--------------------------------------------------------------------
-spec init([Caller::pid()|gsms_uart_config()]) -> 
		  {ok, Ctx::#ctx{}} |
		  {ok, Ctx::#ctx{}, Timeout::timeout()} |
		  ignore |
		  {stop, Reason::term()}.

init([Caller,Opts]) ->
    lager:info("~p: init: args = ~p,\n pid = ~p\n", 
	       [?MODULE, Opts, self()]),
    Opts1 = normalise_opts(?UART_DEFAULT_OPTS ++ Opts),
    {Uopts0,Opts2} = split_opts(Opts1, uart:options()),
    {Gopts0,Opts3} = split_opts(Opts2, options()),
    case check_options(Uopts0,Gopts0,Opts3) of
	ok ->
	    Uopts1 = proplists:delete(device, Uopts0),
	    Device = case proplists:get_value(device, Uopts0) of
			 undefined ->
			     case os:getenv("GSMS_DEVICE") of
				 false -> "";
				 Name -> Name
			     end;
			 Name -> Name
		     end,
	    S = #ctx { device = Device, 
		       uopts  = Uopts1,
		       caller = Caller,
		       opts   = Gopts0,
		       queue  = queue:new()
		     },
	    case open(S) of
		{ok, S1} -> {ok, S1};
		Error -> {stop, Error}
	    end;
	Error ->
	    {stop, Error}
    end.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @end
%%--------------------------------------------------------------------

handle_call({setopts, Opts},_From, Ctx=#ctx { uart = U}) ->
    lager:debug("setopts ~p", [Opts]),
    Opts1 = normalise_opts(Opts),
    {Uopts0,Opts2} = split_opts(Opts1, uart:options()),
    {Gopts0,Opts3} = split_opts(Opts2, options()),
    case check_options(Uopts0,Gopts0,Opts3) of
	ok ->	
	    Uopts1 = proplists:delete(device, Uopts0),
	    case proplists:get_value(device, Uopts0) of
		Device when is_list(Device), Device =/= Ctx#ctx.device ->
		    Uopts2 = normalise_opts(Ctx#ctx.uopts ++ Uopts1),
		    Ctx1 = close(Ctx),
		    Ctx2 = Ctx1#ctx { uart=undefined, 
				      reopen_timer = undefined,
				      device=Device, 
				      uopts=Uopts2, 
				      opts=Gopts0 },
		    case open(Ctx2) of
			{ok, Ctx3} -> {reply,ok,Ctx3};
			Error -> {stop, Error, Ctx2}
		    end;
		_ ->
		    case U of
			undefined ->
			    {reply, {error,no_port}, Ctx};
			simulated ->
			    {reply, ok, Ctx#ctx { uopts=Uopts1, opts=Gopts0} };
			_ ->
			    case uart:setopts(U, Uopts1) of
				ok ->
				    {reply, ok, Ctx#ctx { uopts=Uopts1,
							  opts=Gopts0} };
				Error ->
				    {reply, Error, Ctx}
			    end
		    end
	    end;
	Error ->
	    {reply, Error, Ctx}
    end;

handle_call({subscribe,Pid,Pattern},_From,Ctx=#ctx { subs=Subs}) ->
    Mon = erlang:monitor(process, Pid),
    Subs1 = [#subscription { pid = Pid, mon = Mon, pattern = Pattern}|Subs],
    {reply, {ok,Mon}, Ctx#ctx { subs = Subs1}};
handle_call({unsubscribe,Ref},_From,Ctx) ->
    erlang:demonitor(Ref),
    Ctx1 = remove_subscription(Ref,Ctx),
    {reply, ok, Ctx1};
handle_call(stop, _From, Ctx) ->
    {stop, normal, ok, Ctx};
%% other commands we queue if gsms_uart is busy processing command
handle_call(Call,From,Ctx=#ctx {client = Client}) 
  when Client =/= undefined andalso Call =/= stop ->
    %% Driver is busy ..
    lager:debug("handle_call: Driver busy, store call ~p", [Call]),
    %% set timer already here? probably!
    Q = queue:in({call,Call,From}, Ctx#ctx.queue),
    {noreply, Ctx#ctx { queue = Q }};

handle_call({at,Command},From,Ctx) ->
    lager:debug("handle_call: command ~p", [Command]),
    case Ctx#ctx.uart of
	simulated ->
	    lager:info("simulated output ~p\n", [Command]),
	    {reply, ok, Ctx};
	undefined ->
	    lager:info("~p: No port defined yet.\n", [?MODULE]),
	    {reply, {error,no_port}, Ctx};
	U ->
	    case uart:send(U, ["AT",Command,"\r\n"]) of
		ok ->
		    lager:debug("command: sent"),
		    %% Wait for confirmation
		    Tm=proplists:get_value(reply_timeout,Ctx#ctx.opts,5000),
		    TRef = erlang:start_timer(Tm, self(), reply),
		    {noreply,Ctx#ctx {command = Command,client=From,
				      activity = at,
				      reply = [],
				      reply_timer = TRef}};
		Other ->
		    lager:debug("command: send failed, reason ~p", [Other]),
		    {reply, Other, Ctx}
	    end
    end;

handle_call({ats,Command},From,Ctx) ->
    lager:debug("handle_call: command ~p", [Command]),
    case Ctx#ctx.uart of
	simulated ->
	    lager:info("simulated output ~p\n", [Command]),
	    {reply, ok, Ctx};
	undefined ->
	    lager:info("~p: No port defined yet.\n", [?MODULE]),
	    {reply, {error,no_port}, Ctx};
	U ->
	    uart:setopts(U, [{active,false}]),
	    case uart:send(U, ["AT",Command,"\r\n"]) of
		ok ->
		    lager:debug("command: sent\n", []),
		    %% wait for exacly ">\r\n"
		    uart:setopts(U, [{active,once},{packet,{size,3}}]),
		    %% Wait for confirmation
		    Tm=proplists:get_value(reply_timeout,Ctx#ctx.opts,5000),
		    TRef = erlang:start_timer(Tm, self(), reply),
		    {noreply,Ctx#ctx {command  = Command,client=From,
				      activity = ats,
				      reply = [],
				      reply_timer = TRef}};
		Other ->
		    uart:setopts(U, [{active,true}]),
		    lager:debug("command: send failed, reason ~p", [Other]),
		    {reply, Other, Ctx}
	    end
    end;
%%
%% Send DATA command end with ^Z
%% Hmm how many lines per row ?
%%
handle_call({atd,Hex},From,Ctx) ->
    lager:debug("handle_call: emit ~p", [Hex]),
    case Ctx#ctx.uart of
	simulated ->
	    lager:info("simulated output ~p\n", [Hex]),
	    {reply, ok, Ctx};
	undefined ->
	    lager:info("~p: No port defined yet.\n", [?MODULE]),
	    {reply, {error,no_port}, Ctx};
	U ->
	    case uart:send(U, [Hex,?CTRL_Z]) of
		ok ->
		    lager:debug("command: sent\n", []),
		    %% Wait for confirmation
		    Tm=proplists:get_value(reply_timeout,Ctx#ctx.opts,10000),
		    TRef = erlang:start_timer(Tm, self(), reply),
		    {noreply,Ctx#ctx {command=Hex,client=From,
				      activity = atd,
				      reply = [],
				      reply_timer = TRef}};
		Other ->
		    lager:debug("command: send failed, reason ~p", [Other]),
		    {reply, Other, Ctx}
	    end
    end;    

handle_call(_Request, _From, Ctx) ->
    {reply, {error,bad_call}, Ctx}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Msg::term(), Ctx::#ctx{}) -> 
			 {noreply, Ctx::#ctx{}} |
			 {stop, Reason::term(), Ctx::#ctx{}}.


handle_cast(Cast, Ctx=#ctx {uart = U, client=Client})
  when U =/= undefined, Client =/= undefined ->
    lager:debug("handle_cast: Driver busy, store cast ~p", [Cast]),
    Q = queue:in({cast,Cast}, Ctx#ctx.queue),
    {noreply, Ctx#ctx { queue = Q }};

handle_cast(_Msg, Ctx) ->
    lager:debug("handle_cast: Unknown message ~p", [_Msg]),
    {noreply, Ctx}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @end
%%--------------------------------------------------------------------
-type info()::
	{uart, U::port(), Data::binary()} |
	{uart_error, U::port(), Reason::term()} |
	{uart_closed, U::port()} |
	{timeout, reference(), reply} |
	{timeout, reference(), reopen} |
	{'DOWN',Ref::reference(),process,pid(),Reason::term()}.

-spec handle_info(Info::info(), Ctx::#ctx{}) -> 
			 {noreply, Ctx::#ctx{}} |
			 {stop, Reason::term(), Ctx::#ctx{}}.

handle_info({timeout,TRef,reply}, 
	    Ctx=#ctx {client=Client, reply_timer=TRef}) ->
    lager:debug("handle_info: timeout waiting for port", []),
    gen_server:reply(Client, {error, port_timeout}),
    Ctx1 = Ctx#ctx { reply_timer=undefined, reply=[], client = undefined},
    next_command(Ctx1);

handle_info({uart,U,Data},  Ctx) when U =:= Ctx#ctx.uart ->
    lager:debug("got uart data: ~p\n", [Data]),
    case trim(Data) of
	"" -> %% empty line (may add this later?)
	    {noreply, Ctx};
	">" when Ctx#ctx.activity =:= ats ->
	    uart:setopts(U, [{active,true},{packet,line}]),
	    reply(ready_to_send, Ctx);
	"OK" ->
	    reply(ok, Ctx);
	"ERROR" ->
	    reply(error, Ctx);
	"+CMS ERROR:"++Code ->
	    reply(error, Ctx#ctx { reply=[trimhd(Code)|Ctx#ctx.reply]});
	"+CMTI:"++EventData -> %% new SMS message (stored) arrived
	    Ctx1 = event_notify(cmti,trimhd(EventData), Ctx),
	    {noreply, Ctx1};
	"+CMT:"++EventData -> %% new SMS message arrived
	    Ctx1 = event_notify(cmt,trimhd(EventData), Ctx),
	    {noreply, Ctx1};
	"+CMGS:"++EventData -> %% Send SMS response code
	    Ctx1 = event_notify(cmgs,trimhd(EventData), Ctx),
	    {noreply, Ctx1};
	"+CDSI:"++EventData -> %% SMS status report (stored) arrived
	    Ctx1 = event_notify(cdsi,trimhd(EventData), Ctx),
	    {noreply, Ctx1};
	"+CDS:"++EventData -> %% SMS status report
	    Ctx1 = event_notify(cds,trimhd(EventData), Ctx),
	    {noreply, Ctx1};
	"^"++EventData -> %% Periodic information
	    Ctx1 = event_notify(periodic,trimhd(EventData), Ctx),
	    {noreply,Ctx1};
	Reply ->
	    if Ctx#ctx.client =/= undefined ->
		    lager:debug("handle_info: data ~p", [Reply]),
		    {noreply,Ctx#ctx { reply=[Reply|Ctx#ctx.reply]}};
	       true ->
		    lager:debug("handle_info: noreply ~p", [Reply]),
		    {noreply,Ctx}
	    end
    end;

handle_info({uart_error,U,Reason}, Ctx) when U =:= Ctx#ctx.uart ->
    if Reason =:= enxio ->
	    lager:error("uart error ~p device ~s unplugged?", 
			[Reason,Ctx#ctx.device]);
       true ->
	    lager:error("uart error ~p for device ~s", 
			[Reason,Ctx#ctx.device])
    end,
    {noreply, Ctx};

handle_info({uart_closed,U}, Ctx) when U =:= Ctx#ctx.uart ->
    uart:close(U),
    lager:error("uart close device ~s will retry", [Ctx#ctx.device]),
    case open(Ctx#ctx { uart=undefined}) of
	{ok, Ctx1} -> {noreply, Ctx1};
	Error -> {stop, Error, Ctx}
    end;

handle_info({timeout,Ref,reopen}, Ctx) when Ctx#ctx.reopen_timer =:= Ref ->
    case open(Ctx#ctx { uart=undefined, reopen_timer=undefined}) of
	{ok, Ctx1} -> {noreply, Ctx1};
	Error -> {stop, Error, Ctx}
    end;

handle_info({'DOWN',Ref,process,_Pid,_Reason},Ctx) ->
    lager:debug("handle_info: subscriber ~p terminated: ~p", 
	 [_Pid, _Reason]),
    Ctx1 = remove_subscription(Ref,Ctx),
    {noreply, Ctx1};
handle_info(_Info, Ctx) ->
    lager:debug("handle_info: Unknown info ~p", [_Info]),
    {noreply, Ctx}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason::term(), Ctx::#ctx{}) -> 
		       ok.

terminate(_Reason, Ctx) ->
    close(Ctx),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process ctx when code is changed
%%
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn::term(), Ctx::#ctx{}, Extra::term()) -> 
			 {ok, NewCtx::#ctx{}}.

code_change(_OldVsn, Ctx, _Extra) ->
    {ok, Ctx}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

check_options(Uopts,Gopts,[]) ->
    case uart:validate_opts(Uopts) of
	ok -> validate_opts(Gopts);
	Error -> Error
    end;
check_options(_Uopt,_Gopts,Opts) ->
    {error, {unknown_opts,Opts}}.

	    
open(Ctx=#ctx {device = ""}) ->
    lager:debug("open: simulated\n", []),
    {ok, Ctx#ctx { uart=simulated }};

open(Ctx=#ctx {device = Name, uopts=UOpts }) ->
    case uart:open(Name,UOpts) of
	{ok,U} ->
	    lager:debug("open: ~s [~w]: ~p", [Name,UOpts,U]),
	    flush_uart(U),
	    lager:debug("sync start"),
	    %% waky, waky ? do not echo
	    uart:send(U, [?ESC]),      %% escape if stuck in message send
	    uart:send(U, "ATZ\r\n"),   %% reset 
	    uart:send(U, "ATE0\r\n"),  %% echo off
	    uart:send(U, "AT\r\n"),   %% empty
	    uart:send(U, "AT\r\n"),   %% empty
	    flush_uart(U),
	    lager:debug("sync stop"),
	    %% signal that the the uart device is up running
	    Ctx#ctx.caller ! {gsms_uart, self(), up},
	    {ok, Ctx#ctx { uart=U }};
	{error, E} when E == eaccess;
			E == enoent ->
	    case proplists:get_value(reopen_timeout,Ctx#ctx.opts,infinity) of
		infinity ->
		    lager:debug("open: Driver not started, reason = ~p.\n",[E]),
		    {error, E};
		Ival ->
		    lager:debug("open: uart could not be opened, will try again"
				" in ~p millisecs.\n", [Ival]),
		    Reopen_timer = erlang:start_timer(Ival, self(), reopen),
		    {ok, Ctx#ctx { reopen_timer = Reopen_timer }}
	    end;
	    
	Error ->
	    lager:debug("open: Driver not started, reason = ~p.\n", 
		 [Error]),
	    Error
    end.

close(Ctx=#ctx {uart = U}) when is_port(U) ->
    lager:debug("close: ~p", [U]),
    uart:close(U),
    {ok, Ctx#ctx { uart=undefined }};
close(Ctx) ->
    {ok, Ctx}.


%% flush uart data messages
flush_uart(U) ->
    flush_uart(U, 1000, 250).

flush_uart(U,T0,T1) ->
    receive
	{uart,U,_Data} ->
	    lager:debug("flush: uart ~p\n", [_Data]),
	    flush_uart(U,T1)
    after T0 ->
	    ok
    end.

flush_uart(U,T) ->
    receive
	{uart,U,_Data} ->
	    lager:debug("flush: uart ~p\n", [_Data]),
	    flush_uart(U,T)
    after T ->
	    ok
    end.



reply(Tag, Ctx) ->
    if Ctx#ctx.client =/= undefined ->
	    erlang:cancel_timer(Ctx#ctx.reply_timer),
	    case lists:reverse(Ctx#ctx.reply) of
		[] ->
		    gen_server:reply(Ctx#ctx.client, Tag);
		[Response] ->
		    gen_server:reply(Ctx#ctx.client, {Tag,Response});
		MultiResponse ->
		    gen_server:reply(Ctx#ctx.client, {Tag,MultiResponse})
	    end,
	    Ctx1 = Ctx#ctx { client=undefined, 
			     reply_timer=undefined,
			     activity = none,
			     command = "", reply=[] },
	    next_command(Ctx1);
       true ->
	    {noreply, Ctx}
    end.

next_command(Ctx) ->
    case queue:out(Ctx#ctx.queue) of
	{{value,{call,Call,From}}, Q1} ->
	    case handle_call(Call, From, Ctx#ctx { queue=Q1}) of
		{reply,Reply,Ctx1} ->
		    gen_server:reply(From,Reply),
		    {noreply,Ctx1};
		CallResult ->
		    CallResult
	    end;
	{{value,{cast,Cast}}, Q1} ->
	    handle_cast(Cast, Ctx#ctx { queue=Q1});
	{empty, Q1} ->
	    uart:setopts(Ctx#ctx.uart, [{active,true}]),
	    {noreply, Ctx#ctx { queue=Q1}}
    end.

trimhd([$\s|Cs]) -> trimhd(Cs);
trimhd([$\t|Cs]) -> trimhd(Cs);
trimhd([$\r|Cs]) -> trimhd(Cs);
trimhd([$\n|Cs]) -> trimhd(Cs);
trimhd([0|Cs])   -> trimhd(Cs);
trimhd(Cs) -> Cs.

trimtl(Cs) -> lists:reverse(trimhd(lists:reverse(Cs))).

trim(Cs) -> trimtl(trimhd(Cs)).
	    
unquote([$"|Cs]) ->
    case lists:reverse(Cs) of
	[$"|Cs1] -> lists:reverse(Cs1);
	Cs1 -> Cs1
    end;
unquote(Cs1) -> Cs1.

to_integer(Cs) ->
    try list_to_integer(Cs, 10) of
	Value -> Value
    catch
	error:_ -> Cs
    end.

remove_subscription(Ref, Ctx=#ctx { subs=Subs}) ->
    Subs1 = lists:keydelete(Ref, #subscription.mon, Subs),
    Ctx#ctx { subs = Subs1 }.
    

event_notify(Name,String, Ctx) ->
    Args =
	case string:tokens(String, ",") of
	    [Store,Index] ->
		[{"store",unquote(Store)},{"index",to_integer(Index)}];
	    Items ->
		[{"items", Items}]
	end,
    Event = {Name,Args},
    lager:debug("Event: ~p", [Event]),
    send_event(Ctx#ctx.subs, Event),
    Ctx.

send_event([#subscription{pid=Pid,mon=Ref,pattern=Pattern}|Tail], Event) ->
    case match_event(Pattern, Event) of
	true -> Pid ! {gsms_event,Ref,Event};
	false -> false
    end,
    send_event(Tail,Event);
send_event([],_Event) ->
    ok.

match_event([], _) -> true;
match_event([{Key,ValuePat}|Kvs],Event) ->
    case lists:keyfind(Key, 1, Event) of
	{Key,ValuePat} -> match_event(Kvs, Event);
	_ -> false
    end.

%% split options in two groups {A,B}
%% where A is the group with all keys in Keys B are the rest of the options
split_opts(List, Keys) ->
    {Lists,Rest} = proplists:split(List, Keys),
    List1 =  %% get last element from each list, simulate seq setting
	lists:foldr(fun([],Acc) -> Acc;
		       (L,Acc) -> [lists:last(L)|Acc]
		    end, [], Lists),
    {List1,Rest}.

%% remove duplicate options keep later than earlier options
%% normalise boolean options
normalise_opts([Opt|Opts]) ->
    case Opt of
	Kv={Key,_} ->
	    case proplists:is_defined(Key, Opts) of
		true -> normalise_opts(Opts);
		false -> [Kv|normalise_opts(Opts)]
	    end;
	Key ->
	    case proplists:is_defined(Key, Opts) of
		true -> normalise_opts(Opts);
		false -> [{Key,true}|normalise_opts(Opts)]
	    end
    end;
normalise_opts([]) ->
    [].

validate_opts([{K,V}|Kvs]) ->
    case validate_opt(K,V) of
	true -> validate_opts(Kvs);
	false -> {error,{type_error,K,V}};
	undefined -> {error,{unknown_opt,K}};
	Error -> Error
    end;
validate_opts([]) ->
    ok.

validate_opt(device, Arg) -> is_list(Arg);
validate_opt(reopen_timeout, Arg) -> is_timeout(Arg);
validate_opt(reply_timeout, Arg) -> is_timeout(Arg);
validate_opt(smsc, Arg) -> is_list(Arg);
validate_opt(_,_Arg) -> undefined.

is_timeout(T) ->
    (T =:= infinity) orelse
	(is_integer(T) andalso (T>=0)).
