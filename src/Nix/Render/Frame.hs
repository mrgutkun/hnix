{-# language CPP #-}
{-# language AllowAmbiguousTypes #-}
{-# language ConstraintKinds #-}
{-# language MultiWayIf #-}
{-# language GADTs #-}
{-# language TypeFamilies #-}


-- | Code for rendering/representation of the messages packaged with their context (Frames).
module Nix.Render.Frame where

import           Prelude             hiding ( Comparison )
import           GHC.Exception              ( ErrorCall )
import           Data.Fix                   ( Fix(..) )
import           Nix.Eval
import           Nix.Exec
import           Nix.Expr.Types
import           Nix.Expr.Types.Annotated
import           Nix.Frames
import           Nix.Normal
import           Nix.Options
import           Nix.Pretty
import           Nix.Render
import           Nix.Thunk
import           Nix.Value
import           Prettyprinter       hiding ( list )
import qualified Text.Show                 as Text
import           Text.Megaparsec.Pos        ( sourcePosPretty)
import qualified Text.Show.Pretty          as PS

renderFrames
  :: forall v t f e m ann
   . ( MonadReader e m
     , Has e Options
     , MonadFile m
     , MonadCitedThunks t f m
     , Typeable v
     )
  => Frames
  -> m (Doc ann)
renderFrames []       = stub
renderFrames (x : xs) = do
  opts :: Options <- asks $ view hasLens
  frames          <- if
    | verbose opts <= ErrorsOnly -> renderFrame @v @t @f x
    | verbose opts <= Informational -> do
      f <- renderFrame @v @t @f x
      pure $ concatMap go (reverse xs) <> f
    | otherwise -> concat <$> traverse (renderFrame @v @t @f) (reverse (x : xs))
  pure $
    list
      mempty
      vsep
      frames
 where
  go :: NixFrame -> [Doc ann]
  go f =
    (\ pos -> ["While evaluating at " <> pretty (sourcePosPretty pos) <> colon]) `whenJust` framePos @v @m f

framePos
  :: forall v (m :: Type -> Type)
   . (Typeable m, Typeable v)
  => NixFrame
  -> Maybe SourcePos
framePos (NixFrame _ f)
  | Just (e :: EvalFrame m v) <- fromException f = case e of
    EvaluatingExpr _ (Ann (SrcSpan beg _) _) -> pure beg
    _ -> Nothing
  | otherwise = Nothing

renderFrame
  :: forall v t f e m ann
   . ( MonadReader e m
     , Has e Options
     , MonadFile m
     , MonadCitedThunks t f m
     , Typeable v
     )
  => NixFrame
  -> m [Doc ann]
renderFrame (NixFrame level f)
  | Just (e :: EvalFrame      m v) <- fromException f = renderEvalFrame  level  e
  | Just (e :: ThunkLoop         ) <- fromException f = renderThunkLoop  level  e
  | Just (e :: ValueFrame t f m  ) <- fromException f = renderValueFrame level  e
  | Just (e :: NormalLoop t f m  ) <- fromException f = renderNormalLoop level  e
  | Just (e :: ExecFrame  t f m  ) <- fromException f = renderExecFrame  level  e
  | Just (e :: ErrorCall         ) <- fromException f = pure [pretty (Text.show e)]
  | Just (e :: SynHoleInfo    m v) <- fromException f = pure [pretty (Text.show e)]
  | otherwise = fail $ "Unrecognized frame: " <> show f

wrapExpr :: NExprF r -> NExpr
wrapExpr x = Fix (Fix (NSym "<?>") <$ x)

renderEvalFrame
  :: (MonadReader e m, Has e Options, MonadFile m)
  => NixLevel
  -> EvalFrame m v
  -> m [Doc ann]
renderEvalFrame level f =
  do
    opts :: Options <- asks (view hasLens)
    case f of
      EvaluatingExpr scope e@(Ann ann _) ->
        do
          let
            scopeInfo =
              [pretty $ Text.show scope] `whenTrue` showScopes opts
          fmap
            (\x -> scopeInfo <> [x])
            $ renderLocation ann =<<
                renderExpr level "While evaluating" "Expression" e

      ForcingExpr _scope e@(Ann ann _) | thunks opts ->
        fmap
          (: mempty)
          $ renderLocation ann =<<
              renderExpr level "While forcing thunk from" "Forcing thunk" e

      Calling name ann ->
        fmap
          (: mempty)
          $ renderLocation ann $
              "While calling builtins." <> pretty name

      SynHole synfo ->
        sequenceA $
          let e@(Ann ann _) = _synHoleInfo_expr synfo in

          [ renderLocation ann =<<
              renderExpr level "While evaluating" "Syntactic Hole" e
          , pure $ pretty $ Text.show $ _synHoleInfo_scope synfo
          ]

      ForcingExpr _ _ -> stub


renderExpr
  :: (MonadReader e m, Has e Options, MonadFile m)
  => NixLevel
  -> Text
  -> Text
  -> NExprLoc
  -> m (Doc ann)
renderExpr _level longLabel shortLabel e@(Ann _ x) = do
  opts :: Options <- asks (view hasLens)
  let rendered
          | verbose opts >= DebugInfo =
              pretty (PS.ppShow (stripAnnotation e))
          | verbose opts >= Chatty = prettyNix (stripAnnotation e)
          | otherwise = prettyNix (Fix (Fix (NSym "<?>") <$ x))
  pure $
    bool
      (pretty shortLabel <> fillSep [": ", rendered])
      (vsep [pretty (longLabel <> ":\n>>>>>>>>"), indent 2 rendered, "<<<<<<<<"])
      (verbose opts >= Chatty)

renderValueFrame
  :: forall e t f m ann
   . (MonadReader e m, Has e Options, MonadFile m, MonadCitedThunks t f m)
  => NixLevel
  -> ValueFrame t f m
  -> m [Doc ann]
renderValueFrame level = fmap (: mempty) . \case
  ForcingThunk    _t -> pure "ForcingThunk" -- jww (2019-03-18): NYI
  ConcerningValue _v -> pure "ConcerningValue"
  Comparison     _ _ -> pure "Comparing"
  Addition       _ _ -> pure "Adding"
  Division       _ _ -> pure "Dividing"
  Multiplication _ _ -> pure "Multiplying"

  Coercion       x y -> pure
    $ mconcat [desc, pretty (describeValue x), " to ", pretty (describeValue y)]
   where
    desc =
      bool
      "While coercing "
      "Cannot coerce "
      (level <= Error)

  CoercionToJson v ->
    ("CoercionToJson " <>) <$> renderValue level "" "" v
  CoercionFromJson _j -> pure "CoercionFromJson"
  Expectation t v     ->
    (msg <>) <$> renderValue @_ @t @f @m level "" "" v
   where
    msg = "Expected " <> pretty (describeValue t) <> ", but saw "

renderValue
  :: forall e t f m ann
   . (MonadReader e m, Has e Options, MonadFile m, MonadCitedThunks t f m)
  => NixLevel
  -> Text
  -> Text
  -> NValue t f m
  -> m (Doc ann)
renderValue _level _longLabel _shortLabel v = do
  opts :: Options <- asks $ view hasLens
  bool
    prettyNValue
    prettyNValueProv
    (values opts)
    <$> removeEffects v

renderExecFrame
  :: (MonadReader e m, Has e Options, MonadFile m, MonadCitedThunks t f m)
  => NixLevel
  -> ExecFrame t f m
  -> m [Doc ann]
renderExecFrame level =
  \case
    Assertion ann v ->
      fmap
        (: mempty)
        (do
          d <- renderValue level "" "" v
          renderLocation ann $ fillSep ["Assertion failed:", d]
        )

renderThunkLoop
  :: (MonadReader e m, Has e Options, MonadFile m, Show (ThunkId m))
  => NixLevel
  -> ThunkLoop
  -> m [Doc ann]
renderThunkLoop _level = pure . (: mempty) . \case
  ThunkLoop n -> pretty $ "Infinite recursion in thunk " <> n

renderNormalLoop
  :: (MonadReader e m, Has e Options, MonadFile m, MonadCitedThunks t f m)
  => NixLevel
  -> NormalLoop t f m
  -> m [Doc ann]
renderNormalLoop level =
  fmap
    (: mempty)
    . \case
      NormalLoop v ->
        ("Infinite recursion during normalization forcing " <>) <$> renderValue level "" "" v
