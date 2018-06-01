{-# LANGUAGE OverloadedStrings #-}

module Amy.Bidirectional.TypeCheck
  ( inferModule
  , inferBindingGroup
  , inferBinding
  , inferExpr
  , checkBinding
  , checkExpr
  ) where

import Data.Foldable (for_, traverse_)
import Data.List (foldl')
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import Data.Maybe (maybeToList)
import qualified Data.Sequence as Seq
import Data.Text (pack)
import Data.Traversable (for)

import Amy.Bidirectional.AST as T
import Amy.Bidirectional.Monad
import Amy.Bidirectional.Subtyping
import Amy.Errors
import Amy.Prim
import Amy.Renamer.AST as R
import Amy.Syntax.Located

--
-- Infer
--

inferModule :: R.Module -> Either Error T.Module
inferModule (R.Module bindings externs typeDeclarations) = do
  let
    externs' = convertExtern <$> externs
    typeDeclarations' = (convertTypeDeclaration <$> typeDeclarations) ++ (T.fromPrimTypeDef <$> allPrimTypeDefinitions)

    externTypes = (\(T.Extern name ty) -> (name, ty)) <$> externs'
    primFuncTypes = primitiveFunctionType' <$> allPrimitiveFunctions
    identTypes = externTypes ++ primFuncTypes
    dataConstructorTypes = concatMap mkDataConTypes typeDeclarations'
  runChecker identTypes dataConstructorTypes $ do
    -- Infer type declaration kinds and add to scope
    -- for_ typeDeclarations' $ \decl@(T.TypeDeclaration (T.TyConDefinition tyCon _) _) -> do
    --   kind <- inferTypeDeclarationKind decl
    --   addTyConKindToScope tyCon kind

    -- Infer all bindings
    bindings' <- inferBindingGroup bindings
    pure (T.Module bindings' externs' typeDeclarations')

inferBindingGroup :: [R.Binding] -> Checker [T.Binding]
inferBindingGroup bindings = do
  -- Add all binding group types to context
  for_ bindings $ \(R.Binding (Located _ name) _ _ _) -> do
    ty <- freshTEVar
    addValueTypeToScope name (T.TyExistVar ty)
    modifyContext (|> ContextEVar ty)

  -- Infer each binding individually
  for bindings $ \binding -> do
    binding' <- inferBinding binding
    -- Update type of binding name in State
    -- TODO: Proper binding dependency analysis so this is done in the proper
    -- order
    addValueTypeToScope (T.bindingName binding') (T.bindingType binding')
    pure binding'

inferBinding :: R.Binding -> Checker T.Binding
inferBinding binding@(R.Binding _ mTy _ _) =
  case mTy of
    Just ty -> checkBinding binding (convertScheme ty)
    Nothing -> inferUntypedBinding binding

inferUntypedBinding :: R.Binding -> Checker T.Binding
inferUntypedBinding (R.Binding (Located _ name) _ args expr) = withNewValueTypeScope $ do
  argsAndVars <- for args $ \(Located _ arg) -> do
    ty <- freshTEVar
    addValueTypeToScope arg (TyExistVar ty)
    pure (arg, ty)
  exprVar <- freshTEVar
  let
    allVars = (snd <$> argsAndVars) ++ [exprVar]
  marker <- freshTEVar
  modifyContext (<> Context (Seq.fromList $ ContextMarker marker : (ContextEVar <$> allVars)))
  expr' <- checkExpr expr (TyExistVar exprVar)

  -- Generalize (the Hindley-Milner extension in the paper)
  (contextL, contextR) <- findMarkerHole marker
  let
    unsolvedEVars = contextUnsolved contextR
    mkTVar = TyVarName . ("a" <>) . pack . show . unTyExistVarName
    tyVars = mkTVar <$> unsolvedEVars  -- Would probably use letters and a substitution here
    ty = contextSubst contextR $ foldr1 T.TyFun $ T.TyExistVar <$> allVars
    ty' = foldl' (\t evar -> substituteTEVar evar (T.TyVar $ mkTVar evar) t) ty unsolvedEVars
    tyForall = maybe ty' (\varsNE -> TyForall varsNE ty') $ NE.nonEmpty tyVars
  putContext contextL

  -- Convert binding
  args' <- for argsAndVars $ \(arg, var) -> do
    argTy <- currentContextSubst (T.TyExistVar var)
    pure $ T.Typed argTy arg
  retTy <- currentContextSubst (T.TyExistVar exprVar)
  pure $ T.Binding name tyForall args' retTy expr'

inferExpr :: R.Expr -> Checker T.Expr
inferExpr (R.ELit (Located _ lit)) = pure $ T.ELit lit
inferExpr (R.EVar var) =
  case var of
    R.VVal (Located _ valVar) -> do
      t <- currentContextSubst =<< lookupValueType valVar
      pure $ T.EVar $ T.VVal (T.Typed t valVar)
    R.VCons (Located _ con) -> do
      t <- currentContextSubst =<< lookupDataConType con
      pure (T.EVar $ T.VCons (T.Typed t con))
inferExpr (R.EIf (R.If pred' then' else')) = do
  -- TODO: Is this the right way to do this? Should we actually infer the types
  -- and then unify with expected types? I'm thinking instead we should
  -- instantiate a variable for then/else and check both of them against it,
  -- instead of inferring "then" and using that type to check "else".
  pred'' <- checkExpr pred' (T.TyCon boolTyCon)
  then'' <- inferExpr then'
  else'' <- checkExpr else' (expressionType then'')
  pure $ T.EIf $ T.If pred'' then'' else''
-- inferExpr (EAnn e t) = do
--   context <- getContext
--   liftEither (typeWellFormed context t)
--   checkExpr e t
--   currentContextSubst t
-- inferExpr (ELam x e) = do
--   a <- freshTEVar
--   b <- freshTEVar
--   modifyContext $ \context -> context |> ContextEVar a |> ContextEVar b
--   withNewNameScope $ do
--     addTypeToScope x (TyEVar a)
--     withContextUntil (ContextScopeMarker x) $ do
--       checkExpr e (TyEVar b)
--       currentContextSubst (TyEVar a `TyFun` TyEVar b)
inferExpr (R.ELet (R.Let bindings expression)) = do
  bindings' <- inferBindingGroup bindings
  expression' <- withNewValueTypeScope $ do
    for_ bindings' $ \binding ->
      addValueTypeToScope (T.bindingName binding) (T.bindingType binding)
    inferExpr expression
  pure $ T.ELet (T.Let bindings' expression')
inferExpr (R.EApp f e) = do
  f' <- inferExpr f
  tfSub <- currentContextSubst (expressionType f')
  (e', retTy) <- inferApp tfSub e
  pure (T.EApp $ T.App f' e' retTy)
inferExpr (R.ERecord rows) = do
  rows' <- for (Map.mapKeys locatedValue rows) $ \expr -> do
    expr' <- inferExpr expr
    pure (T.Typed (expressionType expr') expr')
  pure $ T.ERecord rows'
inferExpr (R.ERecordSelect expr (Located _ label)) = do
  retVar <- freshTEVar
  polyVar <- freshTEVar
  modifyContext $ \context -> context |> ContextEVar retVar |> ContextEVar polyVar
  let exprTy = T.TyRecord (Map.singleton label $ T.TyExistVar retVar) (Just $ T.TyExistVar polyVar)
  expr' <- checkExpr expr exprTy
  retTy <- currentContextSubst $ T.TyExistVar retVar
  pure $ T.ERecordSelect expr' label retTy
inferExpr (R.EParens expr) = T.EParens <$> inferExpr expr
inferExpr (R.ECase (R.Case scrutinee matches)) = do
  scrutineeVar <- freshTEVar
  matchVar <- freshTEVar
  modifyContext $ \context -> context |> ContextEVar scrutineeVar |> ContextEVar matchVar
  scrutinee' <- checkExpr scrutinee (T.TyExistVar scrutineeVar)
  matches' <- for matches $ \match -> checkMatch (T.TyExistVar scrutineeVar) match (T.TyExistVar matchVar)
  pure $ T.ECase $ T.Case scrutinee' matches'

inferApp :: T.Type -> R.Expr -> Checker (T.Expr, T.Type)
inferApp (TyForall as t) e = do
  as' <- traverse (const freshTEVar) as
  modifyContext $ \context -> context <> (Context $ Seq.fromList $ NE.toList $ ContextEVar <$> as')
  let t' = foldl' (\ty (a, a') -> instantiate a (TyExistVar a') ty) t $ NE.zip as as'
  inferApp t' e
inferApp (TyExistVar a) e = do
  (a1, a2) <- articulateTyFunExist a
  e' <- checkExpr e (TyExistVar a1)
  t <- currentContextSubst (TyExistVar a2)
  pure (e', t)
inferApp (T.TyFun t1 t2) e = do
  e' <- checkExpr e t1
  t <- currentContextSubst t2
  pure (e', t)
inferApp t e = error $ "Cannot inferApp for " ++ show (t, e)

inferMatch :: T.Type ->  R.Match -> Checker T.Match
inferMatch scrutineeTy (R.Match pat body) = do
  pat' <- checkPattern pat scrutineeTy
  body' <- withNewValueTypeScope $ do
    traverse_ (uncurry addValueTypeToScope) (patternBinderType pat')
    inferExpr body
  pure $ T.Match pat' body'

inferPattern :: R.Pattern -> Checker T.Pattern
inferPattern (R.PLit (Located _ lit)) = pure $ T.PLit lit
inferPattern (R.PVar (Located _ ident)) = do
  tvar <- freshTEVar
  modifyContext (|> ContextEVar tvar)
  pure $ T.PVar $ T.Typed (T.TyExistVar tvar) ident
inferPattern (R.PCons (R.PatCons (Located _ con) mArg)) = do
  conTy <- currentContextSubst =<< lookupDataConType con
  case mArg of
    -- Convert argument and add a constraint on argument plus constructor
    Just arg -> do
      arg' <- inferPattern arg
      let argTy = patternType arg'
      retTy <- freshTEVar
      modifyContext (|> ContextEVar retTy)
      subtype conTy (argTy `T.TyFun` T.TyExistVar retTy) -- Is this right?
      pure $ T.PCons $ T.PatCons con (Just arg') (T.TyExistVar retTy)
    -- No argument. The return type is just the data constructor type.
    Nothing ->
      pure $ T.PCons $ T.PatCons con Nothing conTy
inferPattern (R.PParens pat) = T.PParens <$> inferPattern pat

patternBinderType :: T.Pattern -> Maybe (IdentName, T.Type)
patternBinderType (T.PLit _) = Nothing
patternBinderType (T.PVar (T.Typed ty ident)) = Just (ident, ty)
patternBinderType (T.PCons (T.PatCons _ mArg _)) = patternBinderType =<< mArg
patternBinderType (T.PParens pat) = patternBinderType pat

--
-- Checking
--

checkBinding :: R.Binding -> T.Type -> Checker T.Binding
checkBinding binding t = do
  binding' <- checkBinding' binding t
  -- Restore original type so it looks exactly like the user typed it
  pure $ binding' { T.bindingType = t }

checkBinding' :: R.Binding -> T.Type -> Checker T.Binding
checkBinding' binding (TyForall as t) =
  withContextUntilNE (ContextVar <$> as) $
    checkBinding' binding t
checkBinding' binding t = do
  binding' <- inferUntypedBinding binding
  tSub <- currentContextSubst t
  subtype (T.bindingType binding') tSub
  pure binding'

checkExpr :: R.Expr -> T.Type -> Checker T.Expr
--checkExpr EUnit TyUnit = pure ()
checkExpr e (TyForall as t) =
  withContextUntilNE (ContextVar <$> as) $
    checkExpr e t
-- checkExpr (ELam x e) (TyFun t1 t2) =
--   withNewNameScope $ do
--     addTypeToScope x t1
--     withContextUntil (ContextScopeMarker x) $
--       checkExpr e t2
checkExpr e t = do
  e' <- inferExpr e
  tSub <- currentContextSubst t
  eTy' <- currentContextSubst $ expressionType e'
  subtype eTy' tSub
  pure e'

checkMatch :: T.Type -> R.Match -> T.Type -> Checker T.Match
checkMatch scrutineeTy m t = do
  m' <- inferMatch scrutineeTy m
  tSub <- currentContextSubst t
  mTy' <- currentContextSubst $ matchType m'
  subtype mTy' tSub
  pure m'

checkPattern :: R.Pattern -> T.Type -> Checker T.Pattern
checkPattern pat t = do
  pat' <- inferPattern pat
  tSub <- currentContextSubst t
  mTy' <- currentContextSubst $ patternType pat'
  subtype mTy' tSub
  pure pat'

--
-- Converting types
--

primitiveFunctionType' :: PrimitiveFunction -> (IdentName, T.Type)
primitiveFunctionType' (PrimitiveFunction _ name ty) =
  ( name
  , foldr1 T.TyFun $ T.TyCon <$> ty
  )

convertExtern :: R.Extern -> T.Extern
convertExtern (R.Extern (Located _ name) ty) = T.Extern name (convertType ty)

convertTypeDeclaration :: R.TypeDeclaration -> T.TypeDeclaration
convertTypeDeclaration (R.TypeDeclaration tyName cons) =
  T.TypeDeclaration (convertTyConDefinition tyName) (convertDataConDefinition <$> cons)

convertDataConDefinition :: R.DataConDefinition -> T.DataConDefinition
convertDataConDefinition (R.DataConDefinition (Located _ conName) mTyArg) =
  T.DataConDefinition
  { T.dataConDefinitionName = conName
  , T.dataConDefinitionArgument = convertType <$> mTyArg
  }

mkDataConTypes :: T.TypeDeclaration -> [(DataConName, T.Type)]
mkDataConTypes (T.TypeDeclaration (T.TyConDefinition tyConName tyVars) dataConDefs) = mkDataConPair <$> dataConDefs
 where
  mkDataConPair (T.DataConDefinition name mTyArg) =
    let
      tyVars' = T.TyVar <$> tyVars
      tyApp = foldl1 T.TyApp (T.TyCon tyConName : tyVars')
      ty = foldl1 T.TyFun (maybeToList mTyArg ++ [tyApp])
      tyForall = maybe ty (\varsNE -> TyForall varsNE ty) (NE.nonEmpty tyVars)
    in (name, tyForall)

convertScheme :: R.Scheme -> T.Type
convertScheme (R.Forall vars ty) =
  case NE.nonEmpty vars of
    Just vars' -> T.TyForall (convertTyVarInfo <$> vars') (convertType ty)
    Nothing -> convertType ty

convertType :: R.Type -> T.Type
convertType (R.TyCon (Located _ con)) = T.TyCon con
convertType (R.TyVar var) = T.TyVar (convertTyVarInfo var)
convertType (R.TyApp f arg) = T.TyApp (convertType f) (convertType arg)
convertType (R.TyRecord rows mTail) =
  T.TyRecord
    (Map.mapKeys locatedValue $ convertType <$> rows)
    (T.TyVar . locatedValue <$> mTail)
convertType (R.TyFun ty1 ty2) = T.TyFun (convertType ty1) (convertType ty2)

convertTyConDefinition :: R.TyConDefinition -> T.TyConDefinition
convertTyConDefinition (R.TyConDefinition name' args _) = T.TyConDefinition name' (locatedValue <$> args)

convertTyVarInfo :: Located TyVarName -> T.TyVarName
convertTyVarInfo (Located _ name') = name'

--
-- Substitute
--

substituteTEVar :: TyExistVarName -> T.Type -> T.Type -> T.Type
substituteTEVar _ _ t@(T.TyCon _) = t
substituteTEVar v s t@(TyExistVar v')
  | v == v' = s
  | otherwise = t
substituteTEVar _ _ t@(T.TyVar _) = t
substituteTEVar v s (T.TyApp a b) = T.TyApp (substituteTEVar v s a) (substituteTEVar v s b)
substituteTEVar v s (T.TyRecord rows mTail) = T.TyRecord (substituteTEVar v s <$> rows) (substituteTEVar v s <$> mTail)
substituteTEVar v s (T.TyFun a b) = T.TyFun (substituteTEVar v s a) (substituteTEVar v s b)
substituteTEVar v s (T.TyForall a t) = T.TyForall a (substituteTEVar v s t)
