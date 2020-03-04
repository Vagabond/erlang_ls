-module(els_indexer).

-callback index(els_dt_document:item()) -> ok.

%% TODO: Solve API mix (gen_server and not)
%% API
-export([ find_and_index_file/1
        , find_and_index_file/2
        , index_file/2
        , index/2
        , index_dir/1
        , start_link/0
        , index_apps/0
        , index_deps/0
        , index_otp/0
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , terminate/2
        ]).

%%==============================================================================
%% Includes
%%==============================================================================
-include("erlang_ls.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

%%==============================================================================
%% Types
%%==============================================================================
-type state() :: #{}.

%%==============================================================================
%% Macros
%%==============================================================================
-define(SERVER, ?MODULE).

%%==============================================================================
%% Exported functions
%%==============================================================================
-spec find_and_index_file(string()) ->
   {ok, uri()} | {error, any()}.
find_and_index_file(FileName) ->
  find_and_index_file(FileName, async).

-spec find_and_index_file(string(), async | sync) ->
   {ok, uri()} | {error, any()}.
find_and_index_file(FileName, SyncAsync) ->
  SearchPaths = els_config:get(search_paths),
  case file:path_open(SearchPaths, list_to_binary(FileName), [read]) of
    {ok, IoDevice, FullName} ->
      %% TODO: Avoid opening file twice
      file:close(IoDevice),
      index_file(FullName, SyncAsync);
    {error, Error} ->
      {error, Error}
  end.

-spec index_file(binary(), sync | async) -> {ok, uri()}.
index_file(Path, SyncAsync) ->
  try_index_file(Path, SyncAsync),
  {ok, els_uri:uri(Path)}.

-spec index(uri(), binary()) -> ok.
index(Uri, Text) ->
  MD5 = erlang:md5(Text),
  case els_dt_document:lookup(Uri) of
    {ok, [#{md5 := MD5}]} ->
      ok;
    _ ->
      Document = els_dt_document:new(Uri, Text),
      F = fun() ->
              do_index(Document)
          end,
      els_db:transaction(F)
  end.

-spec do_index(els_dt_document:item()) -> ok.
do_index(#{uri := Uri, id := Id, kind := Kind} = Document) ->
  ok = els_dt_document:insert(Document),
  %% Mapping from document id to uri
  ModuleItem = els_dt_document_index:new(Id, Uri, Kind),
  ok = els_dt_document_index:insert(ModuleItem),
  %% Signatures
  Specs  = els_dt_document:pois(Document, [spec]),
  [els_dt_signatures:insert(#{ mfa  => {Id, F, A}
                             , tree => Tree
                             }) ||
    #{id := {F, A}, data := Tree} <- Specs],
  %% References
  POIs  = els_dt_document:pois(Document, [ application
                                         , implicit_fun
                                         , macro
                                         , record_access
                                         , record_expr
                                         ]),
  ok = els_dt_references:delete_by_uri(Uri),
  [register_reference(Uri, POI) || POI <- POIs],
  ok.

-spec index_apps() -> any().
index_apps() ->
  gen_server:cast(?SERVER, {index_apps}).

-spec index_deps() -> any().
index_deps() ->
  case application:get_env(erlang_ls, index_deps) of
    {ok, true}  -> gen_server:cast(?SERVER, {index_deps});
    {ok, false} -> lager:info("Not indexing dependencies")
  end.

-spec index_otp() -> any().
index_otp() ->
  case application:get_env(erlang_ls, index_otp) of
    {ok, true}  -> gen_server:call(?SERVER, {index_otp}, infinity);
    {ok, false} -> lager:info("Not indexing OTP")
  end.

-spec index_dir(string()) -> {non_neg_integer(), non_neg_integer()}.
index_dir(Dir) ->
  lager:info("Indexing directory. [dir=~s]", [Dir]),
  F = fun(FileName, {Succeeded, Failed}) ->
          case try_index_file(list_to_binary(FileName), sync) of
            ok              -> {Succeeded + 1, Failed};
            {error, _Error} -> {Succeeded, Failed + 1}
          end
      end,
  Filter = fun(Path) ->
               Ext = filename:extension(Path),
               lists:member(Ext, [".erl", ".hrl"])
           end,

  {Time, {Succeeded, Failed}} = timer:tc( els_utils
                                        , fold_files
                                        , [ F
                                          , Filter
                                          , Dir
                                          , {0, 0}
                                          ]
                                        ),
  lager:info("Finished indexing directory. [dir=~s] [time=~p] "
             "[succeeded=~p] "
             "[failed=~p]", [Dir, Time/1000/1000, Succeeded, Failed]),
  {Succeeded, Failed}.

-spec start_link() -> {ok, pid()}.
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, {}, []).

%%==============================================================================
%% gen_server Callback Functions
%%==============================================================================

-spec init({}) -> {ok, state()}.
init({}) ->
  {ok, #{}}.

-spec handle_call(any(), any(), state()) ->
  {noreply, state()} | {reply, ok, state()}.
handle_call({index_otp}, _From, State) ->
  [index_dir(Dir) || Dir <- els_config:get(otp_paths)],
  {reply, ok, State};
handle_call(_Request, _From, State) ->
  {noreply, State}.

-spec handle_cast(any(), state()) -> {noreply, state()}.
handle_cast({index_apps}, State) ->
  [index_dir(Dir) || Dir <- els_config:get(apps_paths)],
  {noreply, State};
handle_cast({index_deps}, State) ->
  [index_dir(Dir) || Dir <- els_config:get(deps_paths)],
  {noreply, State};
handle_cast(_Msg, State) ->
  {noreply, State}.

-spec terminate(any(), state()) -> ok.
terminate(_, _State) ->
  ok.

%%==============================================================================
%% Internal functions
%%==============================================================================

%% @doc Try indexing a file.
-spec try_index_file(binary(), sync | async) -> ok | {error, any()}.
try_index_file(FullName, _SyncAsync) ->
  try
    Uri = els_uri:uri(FullName),
    lager:debug("Indexing file. [filename=~s]", [FullName]),
    {ok, Text} = file:read_file(FullName),
    ok         = index(Uri, Text)
  catch Type:Reason:St ->
      lager:error("Error indexing file "
                  "[filename=~s] "
                  "~p:~p:~p", [FullName, Type, Reason, St]),
      {error, {Type, Reason}}
  end.

-spec register_reference(uri(), poi()) -> ok.
register_reference(Uri, #{kind := Kind, id := RecordName, range := Range})
  when Kind =:= record_expr;
       Kind =:= record_access ->
  els_dt_references:insert(#{ id    => {record, RecordName}
                            , uri   => Uri
                            , range => Range
                            });
register_reference(Uri, #{kind := macro, id := MacroName, range := Range}) ->
  els_dt_references:insert(#{ id    => {macro, MacroName}
                            , uri   => Uri
                            , range => Range
                            });
register_reference(Uri, #{id := {F, A}} = POI) ->
  M = els_uri:module(Uri),
  register_reference(Uri, POI#{id => {M, F, A}});
register_reference(Uri, #{id := {M, F, A}, range := Range}) ->
  els_dt_references:insert(#{ id    => {M, F, A}
                            , uri   => Uri
                            , range => Range
                            }).
