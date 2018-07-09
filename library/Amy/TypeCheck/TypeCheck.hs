{-# LANGUAGE OverloadedStrings #-}

module Amy.TypeCheck.TypeCheck
  ( inferModule
  , inferBindingGroup
  , inferExpr
  , checkBinding
  , checkExpr
  ) where

import Control.Monad (replicateM)
import Control.Monad.Except
import Data.Foldable (for_, traverse_, toList)
import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe, maybeToList)
import qualified Data.Sequence as Seq
import Data.Text (Text, pack)
import Data.Traversable (for, traverse)

import Amy.Errors
import Amy.Prim
import Amy.Syntax.AST as S
import Amy.Syntax.BindingGroups
import Amy.TypeCheck.AST as T
import Amy.TypeCheck.KindInference
import Amy.TypeCheck.Monad
import Amy.TypeCheck.Subtyping

--
-- Infer
--

inferModule :: S.Module -> Either Error T.Module
inferModule (S.Module filePath declarations) = do
  let
    typeDeclarations = mapMaybe declType declarations
    externs = mapMaybe declExtern declarations
    bindings = mapMaybe declBinding declarations
    bindingTypes = mapMaybe declBindingType declarations

    externs' = convertExtern <$> externs
    allTypeDeclarations = allPrimTypeDefinitions ++ typeDeclarations

    externTypes = (\(T.Extern name ty) -> (name, ty)) <$> externs'
    primFuncTypes = primitiveFunctionType' <$> allPrimitiveFunctions
    identTypes = externTypes ++ primFuncTypes
    dataConstructorTypes = concatMap mkDataConTypes (allPrimTypeDefinitions ++ typeDeclarations)
  runChecker identTypes dataConstructorTypes filePath $ do
    -- Infer type declaration kinds and add to scope
    for_ allTypeDeclarations $ \decl@(TypeDeclaration (TyConDefinition tyCon _) _) -> do
      kind <- inferTypeDeclarationKind decl
      addTyConKindToScope tyCon kind

    -- Infer all bindings
    bindings' <- inferBindings True bindings bindingTypes
    pure (T.Module bindings' externs' typeDeclarations)

-- | Compute binding groups and infer each group separately.
inferBindings :: Bool -> [S.Binding] -> [S.BindingType] -> Checker [NonEmpty T.Binding]
inferBindings isTopLevel bindings bindingTypes =
  traverse (inferBindingGroup isTopLevel bindingTypeMap) (bindingGroups bindings)
 where
  bindingTypeMap = Map.fromList $ (\(BindingType (Located _ name) ty) -> (name, ty)) <$> bindingTypes

data BindingTypeStatus
  = TypedBinding !S.Binding !Type
  | UntypedBinding !S.Binding !Type
  deriving (Show, Eq)

compareBindingTypeStatus :: BindingTypeStatus -> BindingTypeStatus -> Ordering
compareBindingTypeStatus TypedBinding{} UntypedBinding{} = LT
compareBindingTypeStatus UntypedBinding{} TypedBinding{} = GT
compareBindingTypeStatus _ _ = EQ

inferBindingGroup :: Bool -> Map IdentName Type -> NonEmpty S.Binding -> Checker (NonEmpty T.Binding)
inferBindingGroup isTopLevel bindingTypeMap bindings = do
  -- Add all binding types to context. Also record whether binding is typed or
  -- untyped
  bindings' <- for bindings $ \binding@(S.Binding lname@(Located _ name) _ _) ->
    case Map.lookup name bindingTypeMap of
      Just ty -> do
        checkTypeKind ty
        addValueTypeToScope lname ty
        pure $ TypedBinding binding ty
      Nothing -> do
        ty <- TyExistVar <$> freshTyExistVar
        addValueTypeToScope lname ty
        pure $ UntypedBinding binding ty

  -- Check/infer each binding. We sort to make sure typed bindings are checked first
  bindings'' <- for (NE.sortBy compareBindingTypeStatus bindings') $ \bindingAndTy ->
    case bindingAndTy of
      TypedBinding binding ty -> do
        binding' <- checkBinding binding ty
        pure $ binding' { T.bindingType = ty }
      UntypedBinding binding ty -> do
        binding' <- inferBinding binding
        tySub <- currentContextSubst ty
        subtype (T.bindingType binding') tySub
        pure binding'

  -- Generalize and apply substitutions to bindings. N.B. we only generalize
  -- top-level bindings, not let bindings.
  context <- getContext
  pure $ flip fmap bindings'' $ \binding ->
    let
      ty = T.bindingType binding
      (ty', context') =
        if isTopLevel
        then generalize context ty
        else (ty, context)
    in
      contextSubstBinding context' $ binding { T.bindingType = ty' }

inferBinding :: S.Binding -> Checker T.Binding
inferBinding (S.Binding (Located nameSpan name) args body) = do
  (args', body', ty, retTy, context) <- inferAbs args body nameSpan
  pure $ contextSubstBinding context $ T.Binding name ty args' retTy body'

-- | Helper to infer both bindings and lambdas
inferAbs
  :: (Traversable t)
  => t (Located IdentName)
  -> S.Expr
  -> SourceSpan
  -> Checker (t (Typed IdentName), T.Expr, Type, Type, Context)
inferAbs args body span' = withSourceSpan span' $ withNewLexicalScope $ do
  argsAndVars <- for args $ \larg@(Located _ arg) -> do
    ty <- freshTyExistVar
    addValueTypeToScope larg (TyExistVar ty)
    pure (arg, ty)
  bodyVar <- freshTyExistVar
  marker <- freshTyExistMarkerVar

  -- Infer body
  body' <- checkExpr body (TyExistVar bodyVar)

  -- Construct the type from arg/body variables
  let ty = foldr1 TyFun $ TyExistVar <$> (toList (snd <$> argsAndVars) ++ [bodyVar])

  -- Convert binding
  args' <- for argsAndVars $ \(arg, var) -> do
    argTy <- currentContextSubst (TyExistVar var)
    pure $ Typed argTy arg
  retTy <- currentContextSubst (TyExistVar bodyVar)

  (contextL, contextR) <- findMarkerHole marker
  putContext contextL
  pure (args', body', ty, retTy, contextL <> contextR)

generalize :: Context -> Type -> (Type, Context)
generalize context ty =
  let
    -- Find unsolved existential variables in the order found in the type. Note
    -- that in general there can be more unsolved existential variables in the
    -- context then there actually are in the type.
    freeVars = freeTEVars $ contextSubst context ty

    -- Replace these with nice letters. TODO: Make sure these letters aren't
    -- already in scope.
    varsWithLetters = zip freeVars (TyVarName <$> letters)
    solutions = uncurry ContextSolved . fmap (TyVar . notLocated) <$> varsWithLetters
    context' = context <> (Context $ Seq.fromList solutions)

    -- Build the forall type
    tyVars = notLocated . snd <$> varsWithLetters
    ty' = contextSubst context' ty
    tyForall = maybe ty' (\varsNE -> TyForall varsNE ty') $ NE.nonEmpty tyVars
  in (tyForall, context')

letters :: [Text]
letters = [1..] >>= fmap pack . flip replicateM ['a'..'z']

inferExpr :: S.Expr -> Checker T.Expr
inferExpr expr = withSourceSpan (expressionSpan expr) $ inferExpr' expr

inferExpr' :: S.Expr -> Checker T.Expr
inferExpr' (S.ELit (Located _ lit)) = pure $ T.ELit lit
inferExpr' (S.EVar lvar@(Located _ valVar)) = do
    t <- currentContextSubst =<< lookupValueType lvar
    pure $ T.EVar $ Typed t valVar
inferExpr' (S.ECon lcon@(Located _ con)) = do
    t <- currentContextSubst =<< lookupDataConType lcon
    pure $ T.ECon $ Typed t con
inferExpr' (S.EIf (S.If pred' then' else' _)) = do
  -- TODO: Is this the right way to do this? Should we actually infer the types
  -- and then unify with expected types? I'm thinking instead we should
  -- instantiate a variable for then/else and check both of them against it,
  -- instead of inferring "then" and using that type to check "else".
  pred'' <- checkExpr pred' (TyCon $ notLocated boolTyCon)
  then'' <- inferExpr then'
  else'' <- checkExpr else' (expressionType then'')
  pure $ T.EIf $ T.If pred'' then'' else''
inferExpr' (S.ELet (S.Let bindings expression _)) = do
  let
    bindings' = mapMaybe letBinding bindings
    bindingTypes = mapMaybe letBindingType bindings
  withNewLexicalScope $ do
    bindings'' <- inferBindings False bindings' bindingTypes
    expression' <- inferExpr expression
    pure $ T.ELet (T.Let bindings'' expression')
inferExpr' (S.ELam (S.Lambda args body span')) = do
  (args', body', ty, _, context) <- inferAbs args body span'
  pure $ contextSubstExpr context $ T.ELam $ T.Lambda args' body' ty
inferExpr' (S.EApp f e) = do
  f' <- inferExpr f
  tfSub <- currentContextSubst (expressionType f')
  (e', retTy) <- inferApp tfSub e
  pure (T.EApp $ T.App f' e' retTy)
inferExpr' (S.ERecord _ rows) = do
  rows' <- fmap Map.fromList $ for (Map.toList rows) $ \(Located _ label, expr) -> do
    expr' <- inferExpr expr
    pure (label, Typed (expressionType expr') expr')
  pure $ T.ERecord rows'
inferExpr' (S.ERecordSelect expr (Located _ label)) = do
  retVar <- freshTyExistVar
  polyVar <- freshTyExistVar
  let exprTy = TyRecord (Map.singleton (notLocated label) $ TyExistVar retVar) (Just $ TyExistVar polyVar)
  expr' <- checkExpr expr exprTy
  retTy <- currentContextSubst $ TyExistVar retVar
  pure $ T.ERecordSelect expr' label retTy
inferExpr' (S.EParens expr) = T.EParens <$> inferExpr expr
inferExpr' (S.ECase (S.Case scrutinee matches _)) = do
  scrutineeVar <- freshTyExistVar
  matchVar <- freshTyExistVar
  scrutinee' <- checkExpr scrutinee (TyExistVar scrutineeVar)
  matches' <- for matches $ \match -> checkMatch (TyExistVar scrutineeVar) match (TyExistVar matchVar)
  pure $ T.ECase $ T.Case scrutinee' matches'

inferApp :: Type -> S.Expr -> Checker (T.Expr, Type)
inferApp (TyForall as t) e = do
  as' <- traverse (const freshTyExistVar) as
  let t' = foldl' (\ty (MaybeLocated _ a, a') -> instantiate a (TyExistVar a') ty) t $ NE.zip as as'
  inferApp t' e
inferApp (TyExistVar a) e = do
  (a1, a2) <- articulateTyFunExist a
  e' <- checkExpr e (TyExistVar a1)
  t <- currentContextSubst (TyExistVar a2)
  pure (e', t)
inferApp (TyFun t1 t2) e = do
  e' <- checkExpr e t1
  t <- currentContextSubst t2
  pure (e', t)
inferApp t e = error $ "Cannot inferApp for " ++ show (t, e)

inferMatch :: Type ->  S.Match -> Checker T.Match
inferMatch scrutineeTy match@(S.Match pat body) =
  withSourceSpan (matchSpan match) $ do
    pat' <- checkPattern pat scrutineeTy
    body' <- withNewLexicalScope $ do
      let
        mBinderNameAndTy = do
          ident <- patternBinderIdent pat
          ty <- patternBinderType pat'
          pure (ident, ty)
      traverse_ (uncurry addValueTypeToScope) mBinderNameAndTy
      inferExpr body
    pure $ T.Match pat' body'

inferPattern :: S.Pattern -> Checker T.Pattern
inferPattern pat = withSourceSpan (patternSpan pat) $ inferPattern' pat

inferPattern' :: S.Pattern -> Checker T.Pattern
inferPattern' (S.PLit (Located _ lit)) = pure $ T.PLit lit
inferPattern' (S.PVar (Located _ ident)) = do
  tvar <- freshTyExistVar
  pure $ T.PVar $ Typed (TyExistVar tvar) ident
inferPattern' (S.PCons (S.PatCons lcon@(Located _ con) mArg)) = do
  conTy <- currentContextSubst =<< lookupDataConType lcon
  case mArg of
    -- Convert argument and add a constraint on argument plus constructor
    Just arg -> do
      arg' <- inferPattern arg
      let argTy = patternType arg'
      retTy <- freshTyExistVar
      subtype conTy (argTy `TyFun` TyExistVar retTy) -- Is this right?
      pure $ T.PCons $ T.PatCons con (Just arg') (TyExistVar retTy)
    -- No argument. The return type is just the data constructor type.
    Nothing ->
      pure $ T.PCons $ T.PatCons con Nothing conTy
inferPattern' (S.PParens pat) = T.PParens <$> inferPattern pat

patternBinderIdent :: S.Pattern -> Maybe (Located IdentName)
patternBinderIdent (S.PLit _) = Nothing
patternBinderIdent (S.PVar ident) = Just ident
patternBinderIdent (S.PCons (S.PatCons _ mArg)) = patternBinderIdent =<< mArg
patternBinderIdent (S.PParens pat) = patternBinderIdent pat

patternBinderType :: T.Pattern -> Maybe Type
patternBinderType (T.PLit _) = Nothing
patternBinderType (T.PVar (Typed ty _)) = Just ty
patternBinderType (T.PCons (T.PatCons _ mArg _)) = patternBinderType =<< mArg
patternBinderType (T.PParens pat) = patternBinderType pat

--
-- Checking
--

checkBinding :: S.Binding -> Type -> Checker T.Binding
checkBinding binding (TyForall as t) =
  withContextUntilNE (ContextVar . maybeLocatedValue <$> as) $
    checkBinding binding t
checkBinding (S.Binding (Located span' name) args body) t = do
  (args', body', bodyTy, context) <- checkAbs args body t span'
  pure $ contextSubstBinding context $ T.Binding name t args' bodyTy body'

-- | Helper to check bindings and lambdas
checkAbs
  :: [Located IdentName]
  -> S.Expr
  -> Type
  -> SourceSpan
  -> Checker ([Typed IdentName], T.Expr, Type, Context)
checkAbs args body t span' =
  withSourceSpan span' $ do
    -- Split out argument and body types
    let
      unfoldedTy = unfoldTyFun t
      numArgs = length args
    when (length unfoldedTy < numArgs + 1) $
      throwAmyError $ TooManyBindingArguments (length unfoldedTy - 1) numArgs
    let
      (argTys, bodyTys) = NE.splitAt numArgs unfoldedTy
      bodyTy = foldr1 TyFun bodyTys

    withNewLexicalScope $ withNewContextScope $ do
      -- Add argument types to scope
      args' <- for (zip args argTys) $ \(larg@(Located _ arg), ty) -> do
        addValueTypeToScope larg ty
        pure $ Typed ty arg

      -- Check body
      body' <- checkExpr body bodyTy

      context <- getContext
      pure (args', body', bodyTy, context)

checkExpr :: S.Expr -> Type -> Checker T.Expr
checkExpr e t = withSourceSpan (expressionSpan e) $ checkExpr' e t

checkExpr' :: S.Expr -> Type -> Checker T.Expr
checkExpr' e (TyForall as t) =
  withContextUntilNE (ContextVar . maybeLocatedValue <$> as) $
    checkExpr e t
checkExpr' (S.ELam (S.Lambda args body span')) t@TyFun{} = do
  (args', body', _, context) <- checkAbs (toList args) body t span'
  pure $ contextSubstExpr context $ T.ELam $ T.Lambda (NE.fromList args') body' t
checkExpr' e t = do
  e' <- inferExpr e
  tSub <- currentContextSubst t
  eTy' <- currentContextSubst $ expressionType e'
  subtype eTy' tSub
  pure e'

checkMatch :: Type -> S.Match -> Type -> Checker T.Match
checkMatch scrutineeTy m t =
  withSourceSpan (matchSpan m) $ do
    m' <- inferMatch scrutineeTy m
    tSub <- currentContextSubst t
    mTy' <- currentContextSubst $ matchType m'
    subtype mTy' tSub
    pure m'

checkPattern :: S.Pattern -> Type -> Checker T.Pattern
checkPattern pat t =
  withSourceSpan (patternSpan pat) $ do
    pat' <- inferPattern pat
    tSub <- currentContextSubst t
    patTy' <- currentContextSubst $ patternType pat'
    subtype patTy' tSub
    pure pat'

--
-- Converting types
--

primitiveFunctionType' :: PrimitiveFunction -> (IdentName, Type)
primitiveFunctionType' (PrimitiveFunction _ name ty) =
  ( name
  , foldr1 TyFun $ TyCon . notLocated <$> ty
  )

convertExtern :: S.Extern -> T.Extern
convertExtern (S.Extern (Located _ name) ty) = T.Extern name ty

mkDataConTypes :: TypeDeclaration -> [(Located DataConName, Type)]
mkDataConTypes (TypeDeclaration (TyConDefinition tyConName tyVars) dataConDefs) = mkDataConPair <$> dataConDefs
 where
  mkDataConPair (DataConDefinition name mTyArg) =
    let
      tyVars' = TyVar . fromLocated <$> tyVars
      tyApp = foldl1 TyApp (TyCon (fromLocated tyConName) : tyVars')
      -- TODO: Should this be foldr? Probably doesn't matter since there is
      -- only one argument currently, but it would break if we added more.
      ty = foldl1 TyFun (maybeToList mTyArg ++ [tyApp])
      tyForall = maybe ty (\varsNE -> TyForall varsNE ty) (NE.nonEmpty $ fromLocated <$> tyVars)
    in (name, tyForall)

--
-- Substitution
--

contextSubstBinding :: Context -> T.Binding -> T.Binding
contextSubstBinding context (T.Binding name ty args retTy body) =
  T.Binding
  { T.bindingName = name
  , T.bindingType = contextSubst context ty
  , T.bindingArgs = contextSubstTyped context <$> args
  , T.bindingReturnType = contextSubst context retTy
  , T.bindingBody = contextSubstExpr context body
  }

contextSubstExpr :: Context -> T.Expr -> T.Expr
contextSubstExpr _ lit@T.ELit{} = lit
contextSubstExpr context (T.ERecord rows) =
  T.ERecord $ (\(Typed ty expr) -> Typed (contextSubst context ty) (contextSubstExpr context expr)) <$> rows
contextSubstExpr context (T.ERecordSelect expr label ty) =
  T.ERecordSelect (contextSubstExpr context expr) label (contextSubst context ty)
contextSubstExpr context (T.EVar var) = T.EVar $ contextSubstTyped context var
contextSubstExpr context (T.ECon con) = T.ECon $ contextSubstTyped context con
contextSubstExpr context (T.EIf (T.If pred' then' else')) =
  T.EIf (T.If (contextSubstExpr context pred') (contextSubstExpr context then') (contextSubstExpr context else'))
contextSubstExpr context (T.ECase (T.Case scrutinee matches)) =
  T.ECase (T.Case (contextSubstExpr context scrutinee) (contextSubstMatch context <$> matches))
contextSubstExpr context (T.ELet (T.Let bindings expr)) =
  T.ELet (T.Let (fmap (contextSubstBinding context) <$> bindings) (contextSubstExpr context expr))
contextSubstExpr context (T.ELam (T.Lambda args body ty)) =
  T.ELam (T.Lambda (contextSubstTyped context <$> args) (contextSubstExpr context body) (contextSubst context ty))
contextSubstExpr context (T.EApp (T.App f arg returnType)) =
  T.EApp (T.App (contextSubstExpr context f) (contextSubstExpr context arg) (contextSubst context returnType))
contextSubstExpr context (T.EParens expr) = T.EParens (contextSubstExpr context expr)

contextSubstTyped :: Context -> Typed a -> Typed a
contextSubstTyped subst (Typed ty x) = Typed (contextSubst subst ty) x

contextSubstMatch :: Context -> T.Match -> T.Match
contextSubstMatch context (T.Match pat body) =
  T.Match (contextSubstPattern context pat) (contextSubstExpr context body)

contextSubstPattern :: Context -> T.Pattern -> T.Pattern
contextSubstPattern _ pat@(T.PLit _) = pat
contextSubstPattern context (T.PVar var) = T.PVar $ contextSubstTyped context var
contextSubstPattern context (T.PCons (T.PatCons con mArg retTy)) =
  let
    mArg' = contextSubstPattern context <$> mArg
    retTy' = contextSubst context retTy
  in T.PCons (T.PatCons con mArg' retTy')
contextSubstPattern context (T.PParens pat) = T.PParens (contextSubstPattern context pat)
