; ModuleID = 'amy-module'
source_filename = "<string>"

@"$str.1" = private global [21 x i8] c"Hello\0Awith\09\22escapes\22\00"

declare i64 @puts(i8*)

define private i8* @hello() {
entry:
  %0 = alloca i8*
  store i8* getelementptr inbounds ([21 x i8], [21 x i8]* @"$str.1", i32 0, i32 0), i8** %0
  %ret = load i8*, i8** %0
  ret i8* %ret
}

define i64 @main() {
entry:
  %x2 = call i8* @hello()
  %x = call i64 @puts(i8* %x2)
  %0 = alloca i64
  store i64 0, i64* %0
  %ret = load i64, i64* %0
  ret i64 %ret
}
