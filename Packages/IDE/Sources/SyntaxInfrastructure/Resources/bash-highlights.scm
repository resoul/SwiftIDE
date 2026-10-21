; Colours for shell scripts, after the highlights.scm of tree-sitter-bash 0.25.1 (MIT), with the
; capture names this application maps (see CaptureKinds). Later patterns paint over earlier ones.

(comment) @comment
((comment) @attribute
  (#match? @attribute "^#!"))

[
  (string)
  (raw_string)
  (ansi_c_string)
  (heredoc_body)
  (heredoc_start)
] @string

(command_name) @function

((command_name) @variable.builtin
  (#match? @variable.builtin "^(echo|printf|cd|pwd|export|unset|set|shift|source|eval|exec|exit|return|read|local|declare|typeset|readonly|alias|unalias|trap|test|true|false|break|continue|wait|kill|type|command|builtin|getopts|umask|ulimit)$"))

(function_definition name: (word) @function)

[
  "case"
  "do"
  "done"
  "elif"
  "else"
  "esac"
  "export"
  "fi"
  "for"
  "function"
  "if"
  "in"
  "select"
  "then"
  "unset"
  "until"
  "while"
  "declare"
  "local"
  "readonly"
  "typeset"
] @keyword

(number) @number
(file_descriptor) @number

[
  (variable_name)
  (special_variable_name)
] @variable.member

(variable_assignment name: (variable_name) @variable.member)

[
  (simple_expansion)
  (expansion)
  (command_substitution)
  (process_substitution)
  (arithmetic_expansion)
] @variable.member

(command argument: (word) @label
  (#match? @label "^-"))

[
  "$"
  "&&"
  "||"
  "|"
  "|&"
  "&"
  ";"
  ";;"
  ">"
  ">>"
  "<"
  "<<"
  "!"
  "=="
  "!="
  "=~"
] @operator
