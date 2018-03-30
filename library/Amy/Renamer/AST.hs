-- | Version of a parser 'Module' after renaming.

module Amy.Renamer.AST
  ( RModule(..)
  , RBinding(..)
  , RExtern(..)
  , RExpr(..)
  , RIf(..)
  , RLet(..)
  , RApp(..)

    -- Re-export
  , Literal(..)
  ) where

import Data.List.NonEmpty (NonEmpty)

import Amy.Literal (Literal(..))
import Amy.Names
import Amy.Prim
import Amy.Type

-- | An 'RModule' is a 'Module' after renaming.
data RModule
  = RModule
  { rModuleBindings :: ![RBinding]
  , rModuleExterns :: ![RExtern]
  }
  deriving (Show, Eq)

-- | A binding after renaming. This is a combo of a 'Binding' and a
-- 'BindingType' after they've been paired together.
data RBinding
  = RBinding
  { rBindingName :: !ValueName
  , rBindingType :: !(Maybe (Type PrimitiveType))
  , rBindingArgs :: ![ValueName]
  , rBindingBody :: !RExpr
  } deriving (Show, Eq)

-- | A renamed extern declaration.
data RExtern
  = RExtern
  { rExternName :: !ValueName
  , rExternType :: !(Type PrimitiveType)
  } deriving (Show, Eq)

-- | A renamed 'Expr'
data RExpr
  = RELit !Literal
  | REVar !ValueName
  | REIf !RIf
  | RELet !RLet
  | REApp !RApp
  deriving (Show, Eq)

data RIf
  = RIf
  { rIfPredicate :: !RExpr
  , rIfThen :: !RExpr
  , rIfElse :: !RExpr
  } deriving (Show, Eq)

data RLet
  = RLet
  { rLetBindings :: ![RBinding]
  , rLetExpression :: !RExpr
  } deriving (Show, Eq)

-- | An 'App' after renaming.
data RApp
  = RApp
  { rAppFunction :: !RExpr
  , rAppArgs :: !(NonEmpty RExpr)
  } deriving (Show, Eq)