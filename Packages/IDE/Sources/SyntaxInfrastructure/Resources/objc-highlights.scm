; Generated from the node types of the pinned grammars by Tools/Grammars/generate_queries.py (do not edit by hand).
; Later patterns win over earlier ones.

; Keywords
[
  "Class" "IBInspectable" "IBOutlet" "_Alignas" "_Alignof" "_Atomic"
  "_Complex" "_Generic" "_Nonnull" "_Noreturn" "_Null_unspecified" "_Nullable"
  "_Nullable_result" "__alignof" "__alignof__" "__asm" "__asm__" "__attribute"
  "__attribute__" "__autoreleasing" "__based" "__block" "__bridge" "__bridge_retained"
  "__bridge_transfer" "__builtin_available" "__catch" "__cdecl" "__clrcall" "__complex"
  "__const" "__contravariant" "__covariant" "__declspec" "__deprecated_enum_msg" "__deprecated_msg"
  "__extension__" "__fastcall" "__finally" "__forceinline" "__imag" "__inline"
  "__inline__" "__kindof" "__nonnull" "__nullable" "__ptrauth_objc_class_ro" "__ptrauth_objc_isa_pointer"
  "__ptrauth_objc_super_pointer" "__real" "__restrict__" "__stdcall" "__strong" "__thiscall"
  "__thread" "__try" "__typeof" "__typeof__" "__unaligned" "__unsafe_unretained"
  "__unused" "__vectorcall" "__volatile__" "__weak" "_alignof" "_unaligned"
  "alignas" "alignof" "asm" "auto" "availability" "break"
  "bycopy" "byref" "case" "class" "const" "constexpr"
  "continue" "default" "defined" "do" "else" "enum"
  "extern" "for" "goto" "id" "if" "in"
  "inline" "inout" "ios" "long" "macos" "macosx"
  "noreturn" "nothrow" "nullable" "objc_bridge_related" "offsetof" "oneway"
  "out" "register" "restrict" "return" "short" "signed"
  "sizeof" "static" "struct" "switch" "thread_local" "tvos"
  "typedef" "typeof" "union" "unsigned" "va_arg" "volatile"
  "watchos" "while"
] @keyword

; Preprocessor directives
[
  "#define" "#elif" "#elifdef" "#elifndef" "#else" "#endif"
  "#if" "#ifdef" "#ifndef" "#import" "#include" "#undef"
] @keyword.directive

; Operators
[
  "!" "!=" "%" "%=" "&" "&&" "&=" "*"
  "*=" "+" "++" "+=" "-" "--" "-=" "->"
  "/" "/=" "<" "<<" "<<=" "<=" "=" "=="
  ">" ">=" ">>" ">>=" "?" "@" "^" "^="
  "|" "|=" "||" "~"
] @operator

"nullptr" @constant.builtin

"NULL" @constant.builtin

; Objective-C keywords, built-in types and macros
[
  "@autoreleasepool" "@available" "@catch" "@compatibility_alias" "@defs" "@dynamic"
  "@encode" "@end" "@finally" "@implementation" "@import" "@interface"
  "@optional" "@package" "@private" "@property" "@protected" "@protocol"
  "@public" "@required" "@selector" "@synchronized" "@synthesize" "@throw"
  "@try"
] @keyword
[
  "availability" "bycopy" "byref" "in" "inout" "ios"
  "macos" "macosx" "nullable" "objc_bridge_related" "oneway" "out"
  "tvos" "watchos"
] @keyword
[
  "BOOL" "Class" "IMP" "SEL" "id"
] @type.builtin
[
  "API_AVAILABLE" "API_DEPRECATED" "API_UNAVAILABLE" "CF_FORMAT_FUNCTION" "CF_RETURNS_NOT_RETAINED" "CF_RETURNS_RETAINED"
  "CG_EXTERN" "CG_INLINE" "DEPRECATED_ATTRIBUTE" "DEPRECATED_MSG_ATTRIBUTE" "FOUNDATION_EXPORT" "FOUNDATION_EXTERN"
  "FOUNDATION_STATIC_INLINE" "IBInspectable" "IBOutlet" "IB_DESIGNABLE" "NS_AUTOMATED_REFCOUNT_UNAVAILABLE" "NS_AVAILABLE"
  "NS_AVAILABLE_IOS" "NS_CLASS_AVAILABLE_IOS" "NS_CLASS_DEPRECATED_IOS" "NS_DEPRECATED_IOS" "NS_ENUM_AVAILABLE_IOS" "NS_ENUM_DEPRECATED_IOS"
  "NS_EXTENSION_UNAVAILABLE_IOS" "NS_FORMAT_FUNCTION" "NS_INLINE" "NS_REQUIRES_NIL_TERMINATION" "NS_ROOT_CLASS" "NS_SWIFT_NAME"
  "NS_SWIFT_UNAVAILABLE" "NS_UNAVAILABLE" "NS_VALID_UNTIL_END_OF_SCOPE" "OBJC_EXPORT" "OBJC_ROOT_CLASS" "UIKIT_EXTERN"
  "UI_APPEARANCE_SELECTOR" "UNAVAILABLE_ATTRIBUTE" "__IOS_AVAILABLE" "__OSX_AVAILABLE_STARTING"
] @attribute

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

; Objective-C
(message_expression method: (identifier) @function)
(method_definition (identifier) @function)
(method_declaration (identifier) @function)
(method_identifier (identifier) @function)
(method_parameter (identifier) @variable.parameter)
(typedefed_specifier) @type
(type_name (typedefed_specifier) @type)
(class_declaration (identifier) @type)
(class_interface "@interface" . (identifier) @type superclass: _? @type)
(class_implementation "@implementation" . (identifier) @type superclass: _? @type)
(protocol_forward_declaration (identifier) @type)
(protocol_reference_list (identifier) @type)
((identifier) @variable.builtin
  (#any-of? @variable.builtin "self" "super"))
(property_attribute (identifier) @keyword)
(module_import path: (identifier) @type)
(availability_attribute_specifier) @attribute
(protocol_qualifier) @keyword
(visibility_specification) @keyword
