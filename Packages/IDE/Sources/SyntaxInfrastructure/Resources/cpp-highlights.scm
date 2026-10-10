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
  "and" "and_eq" "asm" "bitand" "bitor" "break"
  "case" "catch" "class" "co_await" "co_return" "co_yield"
  "compl" "concept" "const" "consteval" "constexpr" "constinit"
  "continue" "decltype" "default" "defined" "delete" "do"
  "else" "enum" "explicit" "extern" "final" "for"
  "friend" "goto" "if" "inline" "long" "mutable"
  "namespace" "new" "noexcept" "noreturn" "not" "not_eq"
  "offsetof" "operator" "or" "or_eq" "override" "private"
  "protected" "public" "register" "requires" "restrict" "return"
  "short" "signed" "sizeof" "static" "static_assert" "struct"
  "switch" "template" "thread_local" "throw" "try" "typedef"
  "typename" "union" "unsigned" "using" "virtual" "volatile"
  "while" "xor" "xor_eq"
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
  "->*" ".*" "/" "/=" "<" "<<" "<<=" "<="
  "<=>" "=" "==" ">" ">=" ">>" ">>=" "?"
  "^" "^=" "|" "|=" "||" "~"
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

; C++
(this) @variable.builtin
(auto) @keyword
(namespace_identifier) @type
(raw_string_literal) @string
(call_expression function: (qualified_identifier name: (identifier) @function))
(call_expression function: (qualified_identifier name: (qualified_identifier name: (identifier) @function)))
(template_function name: (identifier) @function)
(template_method name: (field_identifier) @function)
(function_declarator declarator: (qualified_identifier name: (identifier) @function))
(function_declarator declarator: (field_identifier) @function)
(function_declarator declarator: (destructor_name) @function)
(function_declarator declarator: (operator_name) @function)
(destructor_name) @function
(operator_name) @function
(literal_suffix) @attribute
