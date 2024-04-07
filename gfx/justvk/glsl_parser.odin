package justvk

import "core:fmt"
import "core:strings"

import "jamgine:utils"

Glsl_Parser :: struct {
    lexer : Lexer,
    nodes : utils.Bucket_Array(Glsl_Ast_Node, GLSL_PARSER_TOKEN_BUCKET_SIZE),
    version : int,
    version_token : ^Token,
}
Any_Glsl_Ast  :: union {
    Glsl_Ast_Scope,
    Glsl_Ast_Layout_Item,
    Glsl_Ast_Layout_Qualifier,
    Glsl_Ast_Identifier,
    Glsl_Ast_Var_Decl,
    Glsl_Ast_Type_Decl,
}
Glsl_Ast_Node :: struct {
    token : ^Token,

    variant : Any_Glsl_Ast,
}
Glsl_Ast_Scope :: struct {
    using base : ^Glsl_Ast_Node,

    layout : []^Glsl_Ast_Layout_Item,
    identifiers : [dynamic]^Glsl_Ast_Identifier,
    types : [dynamic]^Glsl_Ast_Type_Decl,
}
Glsl_Layout_Kind :: enum {
    IN, OUT, UNIFORM,
}
Glsl_Ast_Layout_Item :: struct {
    using base : ^Glsl_Ast_Node,

    qualifiers : []^Glsl_Ast_Layout_Qualifier,
    kind : Glsl_Layout_Kind,
    storage_specifier : Glsl_Storage_Specifier,
    decl : ^Glsl_Ast_Var_Decl,
}
Glsl_Layout_Qualifier_Kind :: enum {
    std430, std140, location, binding,
    local_size_x, local_size_y, local_size_z,
    max_vertices, vertices, points, lines, lines_adjacency,
    triangles, triangles_adjacency, xfb_buffer, xfb_offset, xfb_stride,
    index, offset, origin_upper_left, early_fragment_tests,
    push_constant,

    rgba32f, rgba16f, rg32f, rg16f, r11f_g11f_b10f, r32f, r16f,
    rgba16, rgb10_a2, rgba8, rg16, rg8, r16, r8,
    rgba16_snorm, rgba8_snorm, rg16_snorm, rg8_snorm, r16_snorm, r8_snorm,

    rgba32i, rgba16i, rgba8i, rg32i, rg16i, rg8i, r32i, r16i, r8i,

    rgba32ui, rgba16ui, rgb10_a2ui, rgba8ui, rg32ui, rg16ui, rg8ui,
    r32ui, r16ui, r8ui,
}
Glsl_Storage_Specifier :: enum {
    IN, OUT, UNIFORM, BUFFER,
}
Glsl_Ast_Layout_Qualifier :: struct {
    using base : ^Glsl_Ast_Node,

    kind : Glsl_Layout_Qualifier_Kind,
    value : Maybe(int),
}
Glsl_Ast_Identifier :: struct {
    using base : ^Glsl_Ast_Node,
    name : string,
}
Glsl_Ast_Type_Decl :: struct {
    using base : ^Glsl_Ast_Node,

    kind : Glsl_Type_Kind,
    ident : ^Glsl_Ast_Identifier,
    size : int,
    std140_size : int,
    std430_size : int,
    padding : int,
    std140_padding : int,
    std430_padding : int,

    // Only set if kind is .ARRAY
    // If elem_count is 0 it may be dynamically sized array
    elem_type : ^Glsl_Ast_Type_Decl,
    elem_count : int,

    // Only set if kind is .USER_TYPE
    members : []struct{decl : ^Glsl_Ast_Var_Decl, offset, std140_offset, std430_offset : int,},

    type_index : int,
}
Glsl_Ast_Var_Decl :: struct {
    using base : ^Glsl_Ast_Node,
    ident : ^Glsl_Ast_Identifier,
    type : ^Glsl_Ast_Type_Decl,
}

make_ast :: proc(using parser : ^Glsl_Parser, $T : typeid, token : ^Token) -> ^T {
    ast := utils.bucket_array_append(&nodes);

    ast.token = token;
    ast.variant = T{};
    var := &ast.variant.(T);
    var.base = ast;

    return var;
}

Any_Glsl_Parse_Error :: union {
    Glsl_Parse_Error_Unexpected_Token,
    Glsl_Parse_Error_Version_Already_Specified,
    Glsl_Parse_Error_Unknown_Qualifier,
    Glsl_Parse_Error_Undeclared_Identifier,
    Glsl_Parse_Error_Unexpected_Eof,
}
Glsl_Parse_Error :: struct {
    token : ^Token,
    variant : Any_Glsl_Parse_Error,
}
Glsl_Parse_Error_Unexpected_Token :: struct {
    expected : union {string, ^Token},
    got : ^Token,
}
Glsl_Parse_Error_Version_Already_Specified :: struct {
    last_specified_token : ^Token,
    now_specified_token : ^Token,
}
Glsl_Parse_Error_Unknown_Qualifier :: struct {
    token : ^Token,
}
Glsl_Parse_Error_Undeclared_Identifier :: struct {
    token : ^Token,
}
Glsl_Parse_Error_Unexpected_Eof :: struct {
    token : ^Token,
}

make_error :: proc(token : ^Token, err : $T) -> ^Glsl_Parse_Error {
    context.allocator = context.temp_allocator;
    base_err := new(Glsl_Parse_Error);
    base_err.variant = err;
    base_err.token = token;
    return base_err;
}

init_glsl_parser :: proc(parser : ^Glsl_Parser) {
    parser.lexer = make_lexer();
    parser.nodes = utils.make_bucket_array(Glsl_Ast_Node, GLSL_PARSER_TOKEN_BUCKET_SIZE);

    
}
destroy_glsl_parser :: proc(parser : ^Glsl_Parser) {
    destroy_lexer(&parser.lexer);
    utils.delete_bucket_array(&parser.nodes);
}

@(require_results)
expect_token_kind :: proc(token : ^Token, kind : Token_Kind) -> (err : ^Glsl_Parse_Error) {
    if token.kind != kind {
        return make_error(token, Glsl_Parse_Error_Unexpected_Token{
            expected=fmt.tprint(kind),
            got=token,
        });
    }
    return nil;
}
@(require_results)
expect_token_str :: proc(token : ^Token, str : string) -> (err : ^Glsl_Parse_Error) {
    if token.name != str {
        return make_error(token, Glsl_Parse_Error_Unexpected_Token{
            expected=str,
            got=token,
        });
    }
    return nil;
}
expect_token :: proc {
    expect_token_kind,
    expect_token_str,
}

parse_glsl :: proc(using parser : ^Glsl_Parser) -> (result : ^Glsl_Ast_Scope, err : ^Glsl_Parse_Error) {
    return parse_scope(parser, until=.EOF);
}

parse_scope :: proc(using parser : ^Glsl_Parser, until : Token_Kind) -> (result : ^Glsl_Ast_Scope, err : ^Glsl_Parse_Error) {
    first := lexer_peek(&lexer);
    result = make_ast(parser, Glsl_Ast_Scope, first);
    result.identifiers = make(type_of(result.identifiers));
    result.types = make(type_of(result.types));



    // #Limitation
    // Not sure if ever relevant for GLSL but this limits us to one scope
    // and sub scopes wont see these base types.
    for i in 0..<len(Glsl_Type_Kind) {
        kind := cast(Glsl_Type_Kind)i;

        if kind == .USER_TYPE || kind == .ARRAY do continue;

        size := get_glsl_type_size(kind);  

        type := make_ast(parser, Glsl_Ast_Type_Decl, nil);
        type.kind = kind;
        type.size = size;
        type.std140_size = size;
        type.std430_size = size;

        if      kind == .SAMPLER1D do type.ident = make_identifier(parser, result, "sampler1D");
        else if kind == .SAMPLER2D do type.ident = make_identifier(parser, result, "sampler2D");
        else if kind == .SAMPLER3D do type.ident = make_identifier(parser, result, "sampler3D");
        else do type.ident = make_identifier(parser, result, strings.clone(strings.to_lower(fmt.tprintf("%s", kind)))); //#Leak
 
        type.type_index = len(result.types);
        append(&result.types, type);
    }

    layout := make([dynamic]^Glsl_Ast_Layout_Item);

    if first.kind == .OPEN_BRACE do first = lexer_eat(&lexer);

    for true {
        expect_semicolon := false;

        first = lexer_eat(&lexer);
        if first == nil || first.kind == .EOF do break;

        #partial switch first.kind {
            case .HASH: {
                next := lexer_eat(&lexer);

                // #Limitation #Incomplete
                // For now we parse after post processing but when we
                // write our own compiler we will have to parse pre-
                // processing directives as well.
                expect_token(next, "version") or_return;

                switch next.name {
                    case "version": {
                        number_token := lexer_eat(&lexer);

                        expect_token_kind(number_token, .LITERAL_INT) or_return;

                        if parser.version != 0 {
                            return nil, make_error(next, Glsl_Parse_Error_Version_Already_Specified{
                                last_specified_token=parser.version_token,
                                now_specified_token=next,
                            });
                        }
                        parser.version = number_token.literal.(int);
                        parser.version_token = next;
                    }
                    case: {panic("What");}
                }
            }
            case .KW_LAYOUT: {
                layout_item := parse_layout(parser, result) or_return;
                append(&layout, layout_item);
                expect_semicolon = true;
            }
            case .KW_STRUCT: {
                next := lexer_eat(&lexer);
                expect_token_kind(next, .IDENTIFIER) or_return;

                parse_struct(parser, result) or_return;
                expect_semicolon = true;
                // #Incomplete
                // Could be variable declaration after this.
            }
            case .KW_CONST: {
                lexer_eat(&lexer);
                fallthrough;
            }
            case .IDENTIFIER: {
                next := lexer_peek(&lexer, 0);
                next_again := lexer_peek(&lexer, 1);

                // We dont care about these for now
                if next.kind == .IDENTIFIER && next_again.kind == .OPEN_PAR { // Function

                    // Eat name & open par
                    lexer_eat(&lexer);
                    lexer_eat(&lexer);

                    depth := 0;
                    // Skip until )
                    for true {
                        next := lexer_eat(&lexer);
                        if next == nil || next.kind == .EOF {
                            return nil, make_error(next, Glsl_Parse_Error_Unexpected_Eof{token=next});
                        }

                        if next.kind == .OPEN_PAR do depth += 1;
                        if next.kind == .CLOSE_PAR && depth == 0 do break;
                        assert(depth >= 0);
                        if next.kind == .CLOSE_PAR do depth -= 1;
                    }

                    open_brace := lexer_eat(&lexer);
                    expect_token_kind(open_brace, .OPEN_BRACE) or_return;

                    depth = 0;
                    // Skip until }
                    for true {
                        next := lexer_eat(&lexer);
                        if next == nil || next.kind == .EOF {
                            return nil, make_error(next, Glsl_Parse_Error_Unexpected_Eof{token=next});
                        }

                        if next.kind == .OPEN_BRACE do depth += 1;
                        if next.kind == .CLOSE_BRACE && depth == 0 do break;
                        assert(depth >= 0);
                        if next.kind == .CLOSE_BRACE do depth -= 1;
                    }

                } else {
                    expect_semicolon = true;
                    parse_var_decl(parser, result) or_return;

                    next := lexer_peek(&lexer);

                    if next.kind == .EQUALS {
                        // Skip until ;
                        for true {
                            next = lexer_peek(&lexer);
                            if next == nil || next.kind == .EOF {
                                return nil, make_error(next, Glsl_Parse_Error_Unexpected_Eof{token=next});
                            }

                            if next.kind == .SEMICOLON do break;
                            lexer_eat(&lexer);
                        }
                    }
                }
            }
            case: {
                return nil, make_error(first, Glsl_Parse_Error_Unexpected_Token {
                    expected="top-scope declaration",
                    got=first,
                });
            }
        }

        if expect_semicolon {
            next := lexer_eat(&lexer);
            expect_token_kind(next, .SEMICOLON) or_return;
        }
    }

    result.layout = layout[:];

    return;
}

parse_layout :: proc(using parser : ^Glsl_Parser, scope : ^Glsl_Ast_Scope) -> (result : ^Glsl_Ast_Layout_Item, err : ^Glsl_Parse_Error) {
    first := lexer_peek(&lexer, -1);
    assert(first.kind == .KW_LAYOUT, "Parser is lost");

    next := lexer_eat(&lexer);
    expect_token_kind(next, .OPEN_PAR) or_return;

    result = make_ast(parser, Glsl_Ast_Layout_Item, first);
    // #ErrorLeak
    qualifiers := make([dynamic]^Glsl_Ast_Layout_Qualifier);

    for true {
        next = lexer_eat(&lexer);
        expect_token_kind(next, .IDENTIFIER) or_return;
        
        kind, ok := parse_qualifier(next);
        if !ok do return nil, make_error(next, Glsl_Parse_Error_Unknown_Qualifier{token=next});

        qual := make_ast(parser, Glsl_Ast_Layout_Qualifier, first);
        qual.kind = kind;

        next = lexer_eat(&lexer);

        if next.kind == .EQUALS {
            next = lexer_eat(&lexer);
            expect_token_kind(next, .LITERAL_INT) or_return;
            
            qual.value = next.literal.(int);

            next = lexer_eat(&lexer);
        }

        append(&qualifiers, qual);

        if next.kind != .COMMA do break;
    }

    result.qualifiers = qualifiers[:];

    expect_token_kind(next, .CLOSE_PAR) or_return;

    next = lexer_eat(&lexer);

    if next.kind == .KW_FLAT do next = lexer_eat(&lexer);

    if next.kind == .KW_IN {
        result.kind = .IN;
        result.storage_specifier = .IN;
    } else if next.kind == .KW_OUT {
        result.kind = .OUT;
        result.storage_specifier = .OUT;
    } else if next.kind == .KW_UNIFORM || next.kind == .KW_BUFFER {
        result.kind = .UNIFORM;
        result.storage_specifier = .UNIFORM if next.kind == .KW_UNIFORM else .BUFFER;
    } else {
        return nil, make_error(next, Glsl_Parse_Error_Unexpected_Token{got=next, expected="Storage specifier or whatever"});
    }

    next = lexer_peek(&lexer);

    if result.kind == .IN && next.kind == .SEMICOLON {
        return;
    }

    next = lexer_eat(&lexer);

    expect_token_kind(next, .IDENTIFIER) or_return;

    result.decl = parse_var_decl(parser, scope) or_return;

    return;
}
parse_qualifier :: proc(token : ^Token) -> (Glsl_Layout_Qualifier_Kind, bool) {
    for i in 0..<len(Glsl_Layout_Qualifier_Kind) {

        val := cast(Glsl_Layout_Qualifier_Kind)i;

        if token.name == fmt.tprint(val) {
            return val, true;
        }
    }
    return .binding, false;
}

parse_var_decl :: proc(using parser : ^Glsl_Parser, scope : ^Glsl_Ast_Scope) -> (result : ^Glsl_Ast_Var_Decl, err : ^Glsl_Parse_Error) {
    first := lexer_peek(&lexer, -1);
    assert(first.kind == .IDENTIFIER, "Glsl parser is lost");

    next := lexer_peek(&lexer);

    if next.kind == .OPEN_BRACE {
        parse_struct(parser, scope) or_return;
    }
    
    next = lexer_peek(&lexer);

    result = make_ast(parser, Glsl_Ast_Var_Decl, first);

    result.type = infer_type(scope, first.name);
    if result.type == nil {
        return nil, make_error(first, Glsl_Parse_Error_Undeclared_Identifier{token=first});
    }

    if result.type.kind != .USER_TYPE {
        lexer_eat(&lexer);
        expect_token_kind(next, .IDENTIFIER) or_return;

        result.ident = make_identifier(parser, scope, next);
    } else {
        next = lexer_peek(&lexer);

        if next.kind == .IDENTIFIER {
            lexer_eat(&lexer);
            result.ident = make_identifier(parser, scope, next);
        } else {
            result.ident = make_identifier(parser, scope, "UNNAMED");
        }
    }
    next = lexer_peek(&lexer);
    if next.kind == .OPEN_BRACK {
        lexer_eat(&lexer);
        next = lexer_eat(&lexer);

        elem_count := 0;
        if next.kind == .LITERAL_INT {
            elem_count = next.literal.(int);
            next = lexer_eat(&lexer);
        }
        expect_token_kind(next, .CLOSE_BRACK) or_return;

        result.type = arrayify_type(parser, scope, result.type, elem_count);
    }

    return;
}

parse_struct :: proc(using parser : ^Glsl_Parser, scope : ^Glsl_Ast_Scope) -> (result : ^Glsl_Ast_Type_Decl, err : ^Glsl_Parse_Error) {
    first := lexer_peek(&lexer, -1);
    assert(first.kind == .IDENTIFIER, "Glsl parser is lost");

    next := lexer_eat(&lexer);
    expect_token_kind(next, .OPEN_BRACE) or_return;

    result = make_ast(parser, Glsl_Ast_Type_Decl, first);
    result.ident = make_identifier(parser, scope, first);

    result.kind = .USER_TYPE;
    members := make([dynamic]type_of(result.members[0]));
    
    

    STD140_ALIGN :: 16;
    STD430_ALIGN :: 8;
    NORMAL_ALIGN :: 8;
    for true {
        next = lexer_eat(&lexer);
        expect_token_kind(next, .IDENTIFIER) or_return;
        
        decl := parse_var_decl(parser, scope) or_return;

        
        member : type_of(result.members[0]);
        member.decl = decl;
        member.offset = result.size;
        member.std430_offset = member.offset;

        remainder := result.std140_size % STD140_ALIGN;
        if remainder + decl.type.std140_size > STD140_ALIGN {
            member.std140_offset = result.std140_size + remainder;
        } else {
            member.std140_offset = result.std140_size;
        }
        result.std140_size = member.std140_offset + decl.type.std140_size;

        append(&members, member);

        result.size += decl.type.size;
        result.std430_size += decl.type.std430_size;

        next = lexer_eat(&lexer);
        if next.kind != .SEMICOLON do break;

        next = lexer_peek(&lexer);

        if next.kind == .CLOSE_BRACE do break;
    }
    
    result.padding = result.size % NORMAL_ALIGN;
    result.size += result.padding;
    result.std430_padding = result.size % STD430_ALIGN;
    result.std430_size += result.std430_padding;
    result.std140_padding = result.size % STD140_ALIGN;
    result.std140_size += result.std140_padding;
    
    next = lexer_eat(&lexer);
    expect_token_kind(next, .CLOSE_BRACE) or_return;

    result.members = members[:];

    result.type_index = len(scope.types);
    append(&scope.types, result);

    return;
}

infer_type :: proc(scope : ^Glsl_Ast_Scope, name : string) -> (result : ^Glsl_Ast_Type_Decl) {
    
    for type in scope.types {
        if type.ident.name == name do return type;
    }
    return nil;
}
arrayify_type :: proc(using parser : ^Glsl_Parser, scope : ^Glsl_Ast_Scope, type : ^Glsl_Ast_Type_Decl, elem_count : int) -> ^Glsl_Ast_Type_Decl {
    // #Leak #Cleanup
    array_name := utils.sprintf("%s[%i]", type.ident.name, elem_count);

    array_type := make_ast(parser, Glsl_Ast_Type_Decl, type.token);
    array_type.kind = .ARRAY;
    array_type.elem_count = elem_count;
    array_type.elem_type = type;
    array_type.size = elem_count * type.size;
    array_type.std140_size = elem_count * type.std140_size;
    array_type.std430_size = elem_count * type.std430_size;
    array_type.ident = make_identifier(parser, scope, array_name);
    array_type.type_index = len(scope.types);
    append(&scope.types, array_type);

    return array_type;
}

make_identifier_from_token :: proc(using parser : ^Glsl_Parser, scope : ^Glsl_Ast_Scope, token : ^Token) -> ^Glsl_Ast_Identifier {
    ident := make_ast(parser, Glsl_Ast_Identifier, token);
    ident.name = token.name;
    append(&scope.identifiers, ident);
    return ident;
}
make_identifier_from_string :: proc(using parser : ^Glsl_Parser, scope : ^Glsl_Ast_Scope, str : string) -> ^Glsl_Ast_Identifier {
    ident := make_ast(parser, Glsl_Ast_Identifier, nil);
    ident.name = str;
    append(&scope.identifiers, ident);
    return ident;
}
make_identifier :: proc {
    make_identifier_from_string,
    make_identifier_from_token,
}