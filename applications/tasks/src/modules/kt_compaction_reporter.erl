%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2019-, 2600Hz
%%% @doc
%%% @end
%%%-----------------------------------------------------------------------------
-module(kt_compaction_reporter).
-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([start_tracking_job/3
        ,start_tracking_job/4
        ,stop_tracking_job/1
        ,set_job_dbs/2
        ,current_db/2
        ,finished_db/3
        ,skipped_db/2
        ]).
%% Handlers for automatic compaction SUP commands
-export([status/0, history/0, history/1]).

%% gen_server's callbacks
-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,code_change/3
        ,terminate/2
        ]).

-define(SERVER, ?MODULE).
-define(AUTO_COMPACTION_VIEW, <<"auto_compaction/crossbar_listing">>).

-type compaction_stats() :: #{%% Databases
                              'id' => kz_term:ne_binary()
                             ,'found' => pos_integer() %% Number of dbs found to be compacted
                             ,'compacted' => non_neg_integer() %% Number of dbs compacted so far
                             ,'queued' => non_neg_integer() %% remaining dbs to be compacted
                             ,'skipped' => non_neg_integer() %% dbs skipped because not data_size nor disk-data's ratio thresholds are met.
                             ,'current_db' => 'undefined' | kz_term:ne_binary()
                              %% Storage
                             ,'disk_start' => non_neg_integer() %% disk_size sum of all dbs in bytes before compaction (for history sup command)
                             ,'disk_end' => non_neg_integer() %% disk_size sum of all dbs in bytes after compaction (for history sup command)
                             ,'data_start' => non_neg_integer() %% data_size sum of all dbs in bytes before compaction (for history sup command)
                             ,'data_end' => non_neg_integer() %% data_size sum of all dbs in bytes after compaction (for history sup command)
                             ,'recovered_disk' => non_neg_integer() %% bytes recovered so far (auto_compaction status command)
                              %% Worker
                             ,'pid' => pid() %% worker's pid
                             ,'node' => node() %% node where the worker is running
                             ,'started' => kz_time:gregorian_seconds() %% datetime (in seconds) when the compaction started
                             ,'finished' => 'undefined' | kz_time:gregorian_seconds() %% datetime (in seconds) when the compaction ended
                             }.
-type state() ::  #{kz_term:api_ne_binary() => compaction_stats()}.


%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec start_link() -> kz_types:startlink_ret().
start_link() ->
    case gen_server:start_link({'local', ?MODULE}, ?MODULE, [], []) of
        {'error', {'already_started', Pid}} ->
            'true' = link(Pid),
            {'ok', Pid};
        Other -> Other
    end.

%%------------------------------------------------------------------------------
%% @doc Start tracking a compaction job
%% @end
%%------------------------------------------------------------------------------
-spec start_tracking_job(pid(), node(), kz_term:ne_binary()) -> 'ok'.
start_tracking_job(Pid, Node, CallId) ->
    start_tracking_job(Pid, Node, CallId, []).

%%------------------------------------------------------------------------------
%% @doc Start tracking a compaction job
%% @end
%%------------------------------------------------------------------------------
-spec start_tracking_job(pid(), node(), kz_term:ne_binary(), [kt_compactor:db_and_sizes()]) -> 'ok'.
start_tracking_job(Pid, Node, CallId, DbsAndSizes) ->
    gen_server:cast(?SERVER, {'new_job', Pid, Node, CallId, DbsAndSizes}).

%%------------------------------------------------------------------------------
%% @doc Stop tracking compaction job, save current state on db.
%% @end
%%------------------------------------------------------------------------------
-spec stop_tracking_job(kz_term:ne_binary()) -> 'ok'.
stop_tracking_job(CallId) ->
    gen_server:cast(?SERVER, {'stop_job', CallId}).

%%------------------------------------------------------------------------------
%% @doc Some jobs like `compact_all' and `compact_node' doesn't know the list of dbs to
%% be compacted at the beginning of the job, so we wait for that job to report the dbs
%% once it has the list of dbs to be compacted prior to start compacting them.
%% @end
%%------------------------------------------------------------------------------
-spec set_job_dbs(kz_term:ne_binary(), kt_compactor:dbs_and_sizes()) -> 'ok'.
set_job_dbs(CallId, DbsAndSizes) ->
    gen_server:cast(?SERVER, {'set_job_dbs', CallId, DbsAndSizes}).

%%------------------------------------------------------------------------------
%% @doc Set current db being compacted for the given job id.
%% @end
%%------------------------------------------------------------------------------
-spec current_db(kz_term:ne_binary(), kz_term:ne_binary()) -> 'ok'.
current_db(CallId, Db) ->
    gen_server:cast(?SERVER, {'current_db', CallId, Db}).

%%------------------------------------------------------------------------------
%% @doc Set db already compacted for the given job id.
%% @end
%%------------------------------------------------------------------------------
-spec finished_db(kz_term:ne_binary(), kz_term:ne_binary(), kt_compactor:rows()) -> 'ok'.
finished_db(CallId, Db, Rows) ->
    gen_server:cast(?SERVER, {'finished_db', CallId, Db, Rows}).

%%------------------------------------------------------------------------------
%% @doc Notifies when a database has been skipped by the compactor worker. This happens
%% when not data_size nor disk-data's ratio thresholds are met.
%% @end
%%------------------------------------------------------------------------------
-spec skipped_db(kz_term:ne_binary(), kz_term:ne_binary()) -> 'ok'.
skipped_db(CallId, Db) when is_binary(Db) ->
    gen_server:cast(?SERVER, {'skipped_db', CallId, Db}).

%%------------------------------------------------------------------------------
%% @doc SUP command handler
%% @end
%%------------------------------------------------------------------------------
-spec status() -> 'ok'.
status() ->
    %% Result is a list of proplists or an empty list.
    case gen_server:call(?SERVER, 'status') of
        [] ->
            io:format("not running~n");
        StatsRows ->
            lists:foreach(
              fun(Stats) ->
                      lists:foreach(fun({K, V}) -> io:format("~s: ~s~n", [K, V]) end,
                                    Stats),
                      io:format("~n")
              end,
              StatsRows)
    end.

%%------------------------------------------------------------------------------
%% @doc SUP command handler. Returns history for the current Year and Month.
%% @end
%%------------------------------------------------------------------------------
-spec history() -> 'ok'.
history() ->
    {Year, Month, _} = erlang:date(),
    history(Year, Month).

%%------------------------------------------------------------------------------
%% @doc SUP command handler. Accepts `YYYYMM' or `YYYYM' as param to request history
%% for the given Year and Month.
%% @end
%%------------------------------------------------------------------------------
-spec history(kz_term:ne_binary()) -> 'ok'.
history(<<Year:4/binary, Month:2/binary>>) ->
    history(kz_term:to_integer(Year), kz_term:to_integer(Month));
history(<<Year:4/binary, Month:1/binary>>) ->
    history(kz_term:to_integer(Year), kz_term:to_integer(Month));
history(Else) ->
    io:format("Invalid argument *~p*~n", [Else]).

%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Initializes the server.
%% @end
%%------------------------------------------------------------------------------
-spec init([]) -> {'ok', state()}.
init([]) ->
    {'ok', #{}}.

%%------------------------------------------------------------------------------
%% @doc Handling call messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call('status', _From, State) ->
    Ret = maps:fold(fun stats_to_status_fold/3, [], State),
    {'reply', Ret, State};

handle_call(_Request, _From, State) ->
    lager:debug("unhandled call ~p from ~p", [_Request, _From]),
    {'reply', {'error', 'not_implemented'}, State}.

%%------------------------------------------------------------------------------
%% @doc Handling cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
handle_cast({'new_job', Pid, Node, CallId, DbsAndSizes}, State) ->
    {DiskStart, DataStart, TotalDbs} = start_sizes_and_total_dbs(DbsAndSizes),
    Stats = #{'id' => CallId
             ,'found' => TotalDbs
             ,'compacted' => 0
             ,'queued' => TotalDbs
             ,'skipped' => 0
             ,'current_db' => 'undefined'
             ,'disk_start' => DiskStart
             ,'disk_end' => 0
             ,'data_start' => DataStart
             ,'data_end' => 0
             ,'recovered_disk' => 0
             ,'pid' => Pid
             ,'node' => Node
             ,'started' => kz_time:now_s()
             ,'finished' => 'undefined'
             },
    {'noreply', State#{CallId => Stats}};

handle_cast({'stop_job', CallId}, State) ->
    NewState =
        case maps:take(CallId, State) of
            'error' ->
                lager:debug("Invalid id provided for stopping job tracking: ~p", [CallId]),
                State;
            {Stats = #{'started' := Started}, State1} ->
                Finished = kz_time:now_s(),
                Elapsed = Finished - Started,
                lager:debug("~s finished, took ~s (~ps)"
                           ,[CallId, kz_time:pretty_print_elapsed_s(Elapsed), Elapsed]
                           ),
                'ok' = save_compaction_stats(Stats#{'finished' => Finished}),
                State1
        end,
    {'noreply', NewState};

handle_cast({'set_job_dbs', CallId, DbsAndSizes}, State) ->
    NewState =
        case maps:get(CallId, State, 'undefined') of
            'undefined' ->
                State;
            Stats ->
                {DiskStart, DataStart, TotalDbs} = start_sizes_and_total_dbs(DbsAndSizes),
                State#{CallId => Stats#{'found' => TotalDbs
                                       ,'queued' => TotalDbs
                                       ,'disk_start' => DiskStart
                                       ,'data_start' => DataStart
                                       }}
        end,
    {'noreply', NewState};

handle_cast({'current_db', CallId, Db}, State) ->
    NewState =
        case maps:get(CallId, State, 'undefined') of
            'undefined' ->
                State;
            Stats ->
                State#{CallId => Stats#{'current_db' => Db}}
        end,
    {'noreply', NewState};

handle_cast({'finished_db', CallId, Db, [FRow | _]}, State) ->
    NewState =
        case maps:get(CallId, State, 'undefined') of
            'undefined' ->
                State;
            Stats ->
                #{'recovered_disk' := CurrentRec
                 ,'disk_end' := DiskEnd
                 ,'data_end' := DataEnd
                 ,'found' := Found
                 ,'skipped' := Skipped
                 ,'queued' := Queued
                 } = Stats,
                [_, _, OldDisk, _OldData, NewDisk, NewData] = FRow,
                Recovered = (OldDisk-NewDisk),
                NewQueued = Queued - 1,
                lager:debug("recovered ~p bytes after compacting ~p db", [Recovered, Db]),
                State#{CallId => Stats#{'recovered_disk' => CurrentRec + Recovered
                                       ,'disk_end' => DiskEnd + NewDisk
                                       ,'data_end' => DataEnd + NewData
                                       ,'compacted' => Found - NewQueued - Skipped
                                       ,'queued' => NewQueued
                                       ,'current_db' => 'undefined'
                                       }}
        end,
    {'noreply', NewState};

handle_cast({'skipped_db', CallId, Db}, State) ->
    NewState =
        case maps:get(CallId, State, 'undefined') of
            'undefined' ->
                State;
            Stats ->
                lager:debug("~p db does not need compaction, skipped", [Db]),
                Skipped = maps:get('skipped', Stats),
                State#{CallId => Stats#{'skipped' => Skipped + 1}}
        end,
    {'noreply', NewState};

handle_cast(_Msg, State) ->
    lager:debug("unhandled cast ~p", [_Msg]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Handling all non call/cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info(_Info, State) ->
    lager:debug("unhandled message ~p", [_Info]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc This function is called by a `gen_server' when it is about to
%% terminate. It should be the opposite of `Module:init/1' and do any
%% necessary cleaning up. When it returns, the `gen_server' terminates
%% with Reason. The return value is ignored.
%% @end
%%------------------------------------------------------------------------------
-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, _State) ->
    lager:debug("~s terminating with reason: ~p~n when state was: ~p"
               ,[?MODULE, _Reason, _State]
               ).

%%------------------------------------------------------------------------------
%% @doc Convert process state when code is changed.
%% @end
%%------------------------------------------------------------------------------
-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Sum every db's disk_size and data_size in separate variables and then return
%% those as the values for {disk_start, disk_data} and also return the number of dbs
%% within the same tuple, e.g.: {disk_start, disk_data, total_dbs}
%% @end
%%------------------------------------------------------------------------------
-spec start_sizes_and_total_dbs(kt_compactor:dbs_and_sizes()) -> {non_neg_integer()
                                                                 ,non_neg_integer()
                                                                 ,non_neg_integer()
                                                                 }.
start_sizes_and_total_dbs(DbsAndSizes) ->
    lists:foldl(fun start_sizes_and_total_dbs_fold/2, {0, 0, 0}, DbsAndSizes).

-spec start_sizes_and_total_dbs_fold(kt_compactor:db_and_sizes()
                                    ,{non_neg_integer()
                                     ,non_neg_integer()
                                     ,non_neg_integer()
                                     }
                                    ) -> {non_neg_integer()
                                         ,non_neg_integer()
                                         ,non_neg_integer()
                                         }.
start_sizes_and_total_dbs_fold({_Db, {Disk, Data}}, {DiskAcc, DataAcc, Counter}) ->
    {DiskAcc + Disk, DataAcc + Data, Counter + 1};
start_sizes_and_total_dbs_fold({_Db, _}, {DiAcc, DaAcc, Counter}) ->
    %% 'not_found' | 'undefined' sizes
    {DiAcc, DaAcc, Counter + 1}.

-spec stats_to_status_fold(kz_term:ne_binary(), compaction_stats(), [kz_term:proplist()]) ->
                                  [kz_term:proplist()].
stats_to_status_fold(_Key, Stats, Acc) ->
    Keys = ['id', 'found', 'compacted', 'queued', 'skipped', 'current_db',
            'recovered_disk', 'pid', 'node', 'started'],
    [[{kz_term:to_binary(Key), kz_term:to_binary(maps:get(Key, Stats))}
      || Key <- Keys
     ] | Acc].

%%------------------------------------------------------------------------------
%% @doc Print automatic compaction history according to user's input.
%% @end
%%------------------------------------------------------------------------------
-spec history(kz_time:year(), kz_time:month()) -> 'ok'.
history(Year, Month) ->
    {'ok', AccountId} = kapps_util:get_master_account_id(),
    Opts = [{'year', Year}, {'month', Month}, 'include_docs'],
    case kazoo_modb:get_results(AccountId, ?AUTO_COMPACTION_VIEW, Opts) of
        {'ok', []} ->
            io:format("no history found for ~p-~p (year-month)~n", [Year, Month]);
        {'ok', JObjs} ->
            Header = ["id"
                     ,"found"
                     ,"compacted"
                     ,"skipped"
                     ,"recovered"
                     ,"started_at"
                     ,"finished_at"
                     ,"exec_time"
                     ],
            HLine = "+---------------------+------+---------+-------+---------------+-------------------+-------------------+------------+",
            %% Format string for printing header and values of the table including "columns".
            FStr = "|~.21s|~.6s|~.9s|~.7s|~.15s|~.19s|~.19s|~.12s|~n",
            %% Print top line of table, then prints the header and then another line below.
            io:format("~s~n" ++ FStr ++ "~s~n", [HLine] ++ Header ++ [HLine]),
            lists:foreach(fun(Obj) -> print_history_row(Obj, FStr) end, JObjs),
            io:format("~s~n", [HLine])
    end.

-spec print_history_row(kz_json:object(), string()) -> 'ok'.
print_history_row(JObj, FStr) ->
    Doc = kz_json:get_json_value(<<"doc">>, JObj),
    Str = fun(K, From) -> kz_json:get_string_value(K, From) end,
    Int = fun(K, From) -> kz_json:get_integer_value(K, From) end,
    StartInt = Int([<<"worker">>, <<"started">>], Doc),
    EndInt = Int([<<"worker">>, <<"finished">>], Doc),
    DiskStartInt = Int([<<"storage">>, <<"disk">>, <<"start">>], Doc),
    DiskEndInt = Int([<<"storage">>, <<"disk">>, <<"end">>], Doc),
    Row = [Str(<<"_id">>, Doc)
          ,Str([<<"databases">>, <<"found">>], Doc)
          ,Str([<<"databases">>, <<"compacted">>], Doc)
          ,Str([<<"databases">>, <<"skipped">>], Doc)
          ,kz_util:pretty_print_bytes(DiskStartInt - DiskEndInt)
          ,kz_term:to_list(kz_time:pretty_print_datetime(StartInt))
          ,kz_term:to_list(kz_time:pretty_print_datetime(EndInt))
          ,kz_term:to_list(kz_time:pretty_print_elapsed_s(EndInt - StartInt))
          ],
    io:format(FStr, Row).

%%------------------------------------------------------------------------------
%% @doc Save compaction job stats on db.
%% @end
%%------------------------------------------------------------------------------
-spec save_compaction_stats(compaction_stats()) -> 'ok'.
save_compaction_stats(#{'id' := Id
                       ,'found' := Found
                       ,'compacted' := Compacted
                       ,'queued' := Queued
                       ,'skipped' := Skipped
                       ,'disk_start' := DiskStart
                       ,'disk_end' := DiskEnd
                       ,'data_start' := DataStart
                       ,'data_end' := DataEnd
                       ,'pid' := Pid
                       ,'node' := Node
                       ,'started' := Started
                       ,'finished' := Finished
                       } = Stats) ->
    Map = #{<<"_id">> => Id
           ,<<"databases">> => #{<<"found">> => Found
                                ,<<"compacted">> => Compacted
                                ,<<"queued">> => Queued
                                ,<<"skipped">> => Skipped
                                }
           ,<<"storage">> => #{<<"disk">> =>
                                   #{<<"start">> => DiskStart
                                    ,<<"end">> => DiskEnd
                                    }
                              ,<<"data">> =>
                                   #{<<"start">> => DataStart
                                    ,<<"end">> => DataEnd
                                    }
                              }
           ,<<"worker">> => #{<<"pid">> => kz_term:to_binary(Pid)
                             ,<<"node">> => kz_term:to_binary(Node)
                             ,<<"started">> => Started
                             ,<<"finished">> => Finished
                             }
           ,<<"pvt_type">> => <<"compaction_job">>
           ,<<"pvt_created">> => kz_time:now_s()
           },
    lager:debug("Saving stats after compaction job completion: ~p", [Stats]),
    {'ok', AccountId} = kapps_util:get_master_account_id(),
    {'ok', Doc} = kazoo_modb:save_doc(AccountId, kz_json:from_map(Map)),
    lager:debug("Created doc after compaction job completion: ~p", [Doc]),
    'ok'.
