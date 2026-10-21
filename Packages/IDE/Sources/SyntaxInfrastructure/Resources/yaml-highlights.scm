; Colours for YAML, after the highlights.scm of tree-sitter-yaml 0.7.2 (MIT), with the capture
; names this application maps (see CaptureKinds).

(boolean_scalar) @constant.builtin
(null_scalar) @constant.builtin

[
  (double_quote_scalar)
  (single_quote_scalar)
  (block_scalar)
] @string

(escape_sequence) @string.escape

[
  (integer_scalar)
  (float_scalar)
] @number

(comment) @comment

[
  (anchor_name)
  (alias_name)
] @label

(tag) @type

[
  (yaml_directive)
  (tag_directive)
  (reserved_directive)
] @attribute

(block_mapping_pair
  key: (flow_node
    [
      (double_quote_scalar)
      (single_quote_scalar)
    ] @variable.member))

(block_mapping_pair
  key: (flow_node
    (plain_scalar
      (string_scalar) @variable.member)))

(flow_mapping
  (_
    key: (flow_node
      [
        (double_quote_scalar)
        (single_quote_scalar)
      ] @variable.member)))

(flow_mapping
  (_
    key: (flow_node
      (plain_scalar
        (string_scalar) @variable.member))))

[
  ","
  "-"
  ":"
  ">"
  "?"
  "|"
  "["
  "]"
  "{"
  "}"
  "*"
  "&"
  "---"
  "..."
] @operator
