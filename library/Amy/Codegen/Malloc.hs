{-# LANGUAGE OverloadedStrings #-}

module Amy.Codegen.Malloc
  ( callMalloc
  ) where

import LLVM.AST
import LLVM.AST.AddrSpace
import qualified LLVM.AST.CallingConvention as CC
import qualified LLVM.AST.Constant as C
import LLVM.AST.Global as LLVM

import Amy.Codegen.Monad

mallocDefinition :: Global
mallocDefinition =
  functionDefaults
  { name = mallocFunctionName
  , parameters = ([Parameter mallocArgType (UnName 0) []], False)
  , LLVM.returnType = mallocReturnType
  }

mallocFunctionName :: Name
mallocFunctionName = "GC_malloc"

-- N.B. This only applies to 64 bit platforms. We probably need to get the
-- exact malloc type for the target machine.
mallocArgType :: Type
mallocArgType = IntegerType 64

mallocReturnType :: Type
mallocReturnType = PointerType (IntegerType 8) (AddrSpace 0)

mallocFunctionType :: Type
mallocFunctionType =
  FunctionType
  { resultType = mallocReturnType
  , argumentTypes = [mallocArgType]
  , isVarArg = False
  }

callMalloc :: Name -> Maybe Integer -> Type -> BlockGen Operand
callMalloc ptrName mSize ty = do
  -- Make sure malloc definition is generated
  genExternalGlobal mallocDefinition

  -- Compute size of type
  size <- maybe (sizeOfType ty) (pure . ConstantOperand . C.Int 64) mSize

  -- Call malloc
  mallocName <- freshUnName
  let
    funcOp = ConstantOperand $ C.GlobalReference (PointerType mallocFunctionType (AddrSpace 0)) mallocFunctionName
    mallocOp = LocalReference mallocReturnType mallocName
  addInstruction $ mallocName := Call Nothing CC.C [] (Right funcOp) [(size, [])] [] []

  -- Bitcast pointer to what caller intended
  let
    ptrTy = PointerType ty (AddrSpace 0)
    ptrOp = LocalReference ptrTy ptrName
  addInstruction $ ptrName := BitCast mallocOp ptrTy []
  pure ptrOp

-- | Uses getelemtnptr to compute the size of an LLVM type. See
-- https://stackoverflow.com/a/30830445/1333514
sizeOfType :: Type -> BlockGen Operand
sizeOfType ty = do
  -- Compute size of type using getelementptr
  ptrName <- freshUnName
  let
    ptrTy = PointerType ty (AddrSpace 0)
    ptrOp = LocalReference ptrTy ptrName
    nullOp = ConstantOperand $ C.Null ptrTy
  addInstruction $ ptrName := GetElementPtr False nullOp [ConstantOperand (C.Int 32 1)] []

  -- Convert pointer size to an int
  sizeName <- freshUnName
  let
    sizeTy = mallocArgType
    sizeOp = LocalReference sizeTy sizeName
  addInstruction $ sizeName := PtrToInt ptrOp sizeTy []
  pure sizeOp
