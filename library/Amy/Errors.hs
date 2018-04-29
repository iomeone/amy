-- | User facing errors.

module Amy.Errors
  ( Error(..)
  , showError
  , errorLocation
  ) where

import Data.Text (Text)
import Data.Void (Void)
import LLVM.AST (Operand)
import Text.Megaparsec

import Amy.ANF.AST
import Amy.Renamer.AST as R
import Amy.Syntax.Located
import Amy.TypeCheck.AST as T

data Error
  -- Parser
  = ParserError !(ParseError Char Void)

  -- Renamer
  | UnknownVariable !(Located Text)
  | VariableShadowed !(Located Text) !R.Ident
  | UnknownTypeName !(Located Text)
  | NonIdentifierName !(Located Text)

  -- Type checker
  -- TODO: Add source spans here
  | UnificationFail !T.Type !T.Type
  | InfiniteType T.TypeName !T.Type
  | UnboundVariable !T.Ident

  -- | BindingLacksTypeSignature !RBinding
  -- | TypeMismatch !(Type PrimitiveType) !(Type PrimitiveType)
  -- | CantFindType !(Located Name)
  -- | WrongNumberOfArguments !Int !Int
  -- | ExpectedPrimitiveType !(Maybe (Located Name)) !(Type PrimitiveType)
  -- | ExpectedFunctionType !(Type PrimitiveType)

  -- Codegen
  | CodegenMissingSymbol !ANFIdent
  | NoCurrying !T.App
  | UnknownOperandType !Operand
  deriving (Show, Eq)

errorLocation :: Error -> Maybe SourceSpan
errorLocation e =
  case e of
    ParserError{} -> Nothing
    UnknownVariable (Located s _) -> Just s
    VariableShadowed (Located s _) _ -> Just s
    UnknownTypeName (Located s _) -> Just s
    NonIdentifierName (Located s _) -> Just s

    UnificationFail{} -> Nothing
    InfiniteType{} -> Nothing
    UnboundVariable{} -> Nothing

    -- BindingLacksTypeSignature bind -> Just $ locatedSpan $ rBindingName bind
    -- TypeMismatch{} -> Nothing
    -- CantFindType{} -> Nothing
    -- WrongNumberOfArguments{} -> Nothing
    -- ExpectedPrimitiveType mLocated _ -> locatedSpan <$> mLocated
    -- ExpectedFunctionType{} -> Nothing

    CodegenMissingSymbol{} -> Nothing
    NoCurrying{} -> Nothing
    UnknownOperandType{} -> Nothing

showError :: Error -> String
showError (ParserError err) = parseErrorPretty err
showError err = show err
