# -*- coding: utf-8 -*-
# Builds the highlight queries of the C family from the node types of the pinned grammars, so
# that every keyword and operator token of the grammar is covered. Output is committed.
import json, re, io
import os
here=os.path.dirname(os.path.abspath(__file__))
repo=os.path.dirname(os.path.dirname(here))
root=os.path.join(repo,'Packages/IDE/.build/checkouts')   # after `swift package resolve` in Packages/IDE
out=os.path.join(repo,'Packages/IDE/Sources/SyntaxInfrastructure/Resources')
def anon(g):
    nt=json.load(open(f'{root}/{g}/src/node-types.json'))
    return sorted({n['type'] for n in nt if not n['named']}), {n['type'] for n in nt if n['named']}
def q(tokens): return ' '.join('"%s"'%t.replace('\\','\\\\').replace('"','\\"') for t in tokens)
def wrap(tokens, capture, per=6):
    lines=[]
    for i in range(0,len(tokens),per): lines.append('  '+q(tokens[i:i+per]))
    return '[\n'+'\n'.join(lines)+'\n] @'+capture+'\n'

OPS_EXCLUDE={'"', "'", '(', ')', '[', ']', '{', '}', ';', ',', '.', '...', ':', '::', '\n', '[[', ']]', '()', '[]', '""','(class)'}
def split(g, extra_constants=()):
    a,named=anon(g)
    words=[x for x in a if re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*',x)]
    at=[x for x in a if re.fullmatch(r'@[A-Za-z_][A-Za-z_0-9]*',x)]
    pre=[x for x in a if x.startswith('#') and len(x)>1]
    ops=[x for x in a if not re.fullmatch(r'@?[A-Za-z_#][A-Za-z_0-9]*',x) and x not in OPS_EXCLUDE and not x.endswith('"') and not x.endswith("'") and x!='#' ]
    return words,at,pre,ops,named

HEADER='; Generated from the node types of the pinned grammars by Tools/Grammars/generate_queries.py (do not edit by hand).\n; Later patterns win over earlier ones.\n\n'

BASE_AFTER = r'''
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
'''

def c_base(g):
    words,at,pre,ops,named=split(g)
    consts={'NULL','nullptr'}
    kw=[w for w in words if w not in consts and not w.startswith('NS_') and not w.startswith('API_') and not w.isupper()]
    s=HEADER
    s+='; Keywords\n'+wrap(kw,'keyword')
    s+='\n; Preprocessor directives\n'+wrap(pre,'keyword.directive')
    s+='\n; Operators\n'+wrap(ops,'operator',8)
    if 'nullptr' in words:
        s+='\n"nullptr" @constant.builtin\n'
    s+='\n"NULL" @constant.builtin\n' if 'NULL' in words else ''
    return s, named

CPP_EXTRA = r'''
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
'''

OBJC_EXTRA = r'''
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
'''

# C
base,_=c_base('tree-sitter-c')
io.open(f'{out}/c-highlights.scm','w',encoding='utf-8').write(base+BASE_AFTER)
# C++
base,named=c_base('tree-sitter-cpp')
io.open(f'{out}/cpp-highlights.scm','w',encoding='utf-8').write(base+BASE_AFTER+CPP_EXTRA)
# Objective-C
words,at,pre,ops,named=split('tree-sitter-objc')
base,_=c_base('tree-sitter-objc')
macro=[w for w in words if (w.startswith('NS_') or w.startswith('API_') or w.isupper() or w.startswith('CF_') or w.startswith('IB') or w.startswith('__IOS') or w.startswith('__OSX') or w.startswith('UI') or w.startswith('OBJC') or w.startswith('FOUNDATION') or w.startswith('CG_') or w.startswith('DEPRECATED') or w.startswith('UNAVAILABLE')) and w not in ('NULL','BOOL','IMP','SEL')]
builtin=[w for w in words if w in ('BOOL','IMP','SEL','Class','id')]
kw_extra=[w for w in words if w in ('in','out','inout','bycopy','byref','oneway','nullable','nonnull','ios','macos','macosx','tvos','watchos','availability','objc_bridge_related')]
extra=''
extra+='\n; Objective-C keywords, built-in types and macros\n'+wrap(at,'keyword')+wrap(kw_extra,'keyword')+wrap(builtin,'type.builtin')+wrap(macro,'attribute')
io.open(f'{out}/objc-highlights.scm','w',encoding='utf-8').write(base+extra+BASE_AFTER+OBJC_EXTRA)
print('ok')
