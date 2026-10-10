; Generated from the node types of the pinned grammars by Tools/Grammars/generate_queries.py (do not edit by hand).
; Later patterns win over earlier ones.

; Keywords
[
  "_Alignas" "_Alignof" "_Atomic" "_Generic" "_Nonnull" "_Noreturn"
  "__alignof" "__alignof__" "__asm" "__asm__" "__attribute" "__attribute__"
  "__based" "__cdecl" "__clrcall" "__declspec" "__except" "__extension__"
  "__fastcall" "__finally" "__forceinline" "__inline" "__inline__" "__leave"
  "__restrict__" "__stdcall" "__thiscall" "__thread" "__try" "__unaligned"
  "__vectorcall" "__volatile__" "_alignof" "_unaligned" "alignas" "alignof"
  "asm" "auto" "break" "case" "const" "constexpr"
  "continue" "default" "defined" "do" "else" "enum"
  "extern" "for" "goto" "if" "inline" "long"
  "noreturn" "offsetof" "register" "restrict" "return" "short"
  "signed" "sizeof" "static" "struct" "switch" "thread_local"
  "typedef" "union" "unsigned" "volatile" "while"
] @keyword

; Preprocessor directives
[
  "#define" "#elif" "#elifdef" "#elifndef" "#else" "#endif"
  "#if" "#ifdef" "#ifndef" "#include"
] @keyword.directive

; Operators
[
  "!" "!=" "%" "%=" "&" "&&" "&=" "*"
  "*=" "+" "++" "+=" "-" "--" "-=" "->"
  "/" "/=" "<" "<<" "<<=" "<=" "=" "=="
  ">" ">=" ">>" ">>=" "?" "^" "^=" "|"
  "|=" "||" "~"
] @operator

"nullptr" @constant.builtin

"NULL" @constant.builtin

; Literals and comments
(comment) @comment
(string_literal) @string
(system_lib_string) @string
(char_literal) @string
(escape_sequence) @string.escape
(number_literal) @number
(true) @constant.builtin
(false) @constant.builtin
(null) @constant.builtin

; Identifiers: the general rule first, the specific ones after it
((identifier) @constant
  (#match? @constant "^[A-Z][A-Z0-9_]*$"))
(field_identifier) @variable.member
(statement_identifier) @label
(type_identifier) @type
(primitive_type) @type.builtin
(sized_type_specifier) @type.builtin

; Functions
(call_expression function: (identifier) @function)
(call_expression function: (field_expression field: (field_identifier) @function))
(function_declarator declarator: (identifier) @function)
(function_declarator declarator: (parenthesized_declarator (identifier) @function))
(parameter_declaration declarator: (identifier) @variable.parameter)
(parameter_declaration declarator: (pointer_declarator declarator: (identifier) @variable.parameter))
(parameter_declaration declarator: (array_declarator declarator: (identifier) @variable.parameter))

; The preprocessor
(preproc_directive) @keyword.directive
(preproc_def name: (identifier) @function.macro)
(preproc_function_def name: (identifier) @function.macro)
(preproc_ifdef name: (identifier) @function.macro)
(preproc_defined (identifier) @function.macro)
(preproc_call directive: (preproc_directive) @keyword.directive)

; Attributes
(attribute_specifier) @attribute
(attribute_declaration) @attribute
