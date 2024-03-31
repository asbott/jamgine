package justvk

// General purpose lexer from another project

import "core:fmt"
import "core:os"
import "core:io"
import "core:mem"
import "core:math"
import "core:strings"
import "core:strconv"
import "core:time"

import "jamgine:utils"

print :: fmt.print;
char :: u8;

find_index :: proc(arr : ^$T/[]$E, item : E) -> int {
    mem.arena_allocator_pro
    c()
    for index, it in arr {
        if it == item do return index;
    }
    return -1;
}

Literal_Value :: union { int, f32, f64, string }

Token_Kind :: enum {
    EOF = 0,

    COLON = ':', SEMICOLON = ';', EQUALS = '=', PLUS = '+',
    MINUS = '-', MULTIPLY = '*', DIVIDE = '/', OPEN_BRACE = '{',
    CLOSE_BRACE = '}', OPEN_PAR = '(', CLOSE_PAR = ')',
    COMMA = ',', DOT = '.', GREATERTHAN = '>', LESSTHAN = '<', NOT = '!', 
    QUESTIONMARK = '?', BIT_AND = '&', BIT_OR = '|', BIT_XOR = '^',
    BIT_NOT = '~', OPEN_BRACK = '[', CLOSE_BRACK = ']',

    STAR = '*', AT = '@', HASH = '#', PERCENT = '%', DOLLAR = '$',

    ASCII_MAX = 256,

    LITERAL_INT, LITERAL_F32, LITERAL_F64,
    LITERAL_STRING,
    IDENTIFIER,

    KW_RETURN, KW_IF, KW_WHILE, KW_ELSE, KW_CONTINUE, KW_BREAK, 
    KW_STRUCT, KW_CONST, KW_LAYOUT,
    KW_IN, KW_OUT, KW_UNIFORM, KW_FLAT, KW_BUFFER,

    PLUSEQUALS, /* += */ MINUSEQUALS, /* -= */ MULTIPLYEQUALS, /* *= */
    DIVIDEEQUALS, /* /= */ MODULOEQUALS, /* %= */ BIT_AND_EQUALS, /* &= */
    BIT_OR_EQUALS, /* |= */ BIT_XOR_EQUALS, /* ^= */
    ASSIGN_FIRST = PLUSEQUALS,
    ASSIGN_LAST = BIT_XOR_EQUALS,

    RIGHT_ARROW, /* -> */ LEFT_ARROW, /* <- */ DOUBLEEQUALS, /* == */
    NOTEQUALS, /* != */ GREATERTHANEQUALS, /* >= */ LESSTHANEQUALS, /* <= */
    DOUBLEAND, /* && */ DOUBLEOR, /* || */ XOR, /* !| */ POW, /* ^^ */
    SHIFT_LEFT, /* << */ SHIFT_RIGHT, /* >> */ 

    UNKNOWN,
    INVALID,
};
 

// Rune integer value == Token_Kind
single_punctuation_set :: []char {
    '+', '-', '/', '*', '=', '(', ')', '{', '}', ';', ':', 
    ',', '.', '>', '<', '!', '&', '|', '^', '~', '@', '#',
    '%', '$', '?', '[', ']',
}
punctuation_set :: [] struct { str:string, kind:Token_Kind } {
    {"+=", .PLUSEQUALS},     {"-=", .MINUSEQUALS}, 
    {"*=", .MULTIPLYEQUALS}, {"/=", .DIVIDEEQUALS}, 
    {"%=", .MODULOEQUALS},   {"&=", .BIT_AND_EQUALS}, 
    {"|=", .BIT_OR_EQUALS},  {"^=", .BIT_XOR_EQUALS}, 
    {"->", .RIGHT_ARROW},    {"<-", .LEFT_ARROW},
    {"==", .DOUBLEEQUALS},   {"!=", .NOTEQUALS},
    {"&&", .DOUBLEAND},      {"||", .DOUBLEOR},
    {"|!", .XOR},            {">=", .GREATERTHANEQUALS},
    {"<=", .LESSTHANEQUALS}, {"^^", .POW},
    {"<<", .SHIFT_LEFT},     {">>", .SHIFT_RIGHT},
}
keyword_set :: [] struct {kind:Token_Kind,str:string} {
    {.KW_RETURN, "return"},     {.KW_IF, "if"},             {.KW_WHILE, "while"}, 
    {.KW_ELSE, "else"},         {.KW_CONTINUE, "continue"}, {.KW_BREAK, "break"}, 
    {.KW_STRUCT, "struct"},     {.KW_CONST, "const"},       {.KW_LAYOUT, "layout"}, 
    {.KW_IN, "in"},             {.KW_OUT, "out"},           {.KW_UNIFORM, "uniform"},   
    {.KW_FLAT, "flat"},         {.KW_BUFFER, "buffer"},
};
try_punctuation :: proc(s: string) -> (bool, Token_Kind) {
    for pair in punctuation_set {
        if pair.str == s do return true, pair.kind;
    }
    return false, .INVALID;
}
is_single_punctuation :: proc(csrc: char) -> bool {
    for c in single_punctuation_set do if c == csrc do return true;
    return false;
}
try_keyword :: proc(s: string) -> (bool, Token_Kind) {
    for pair in keyword_set {
        if pair.str == s do return true, pair.kind;
    }
    return false, .INVALID;
}

Source_File :: struct {
    content : string,
    lines   : []string,
    path    : string,
}

lex_source :: proc(lexer : ^Lexer, src_text: string, allocator := context.allocator) -> Source_File {

    context.allocator = allocator;

    src : Source_File;

    src.content = strings.clone(src_text);
    src.lines = strings.split_lines(src.content);

    src.path = "RUNTIME_SOURCE";

    lex_entire_file(lexer, src);

    return src;
}
lex_file :: proc(lexer : ^Lexer, path: string, allocator := context.allocator) -> Source_File {

    context.allocator = allocator;

    src : Source_File;
    
    data, success := os.read_entire_file(path);
    assert(success, "Could not find file")

    allocated := false;
    src.content, allocated = strings.replace_all(string(data), "\r\n", "\n");

    src.lines = strings.split_lines(src.content);

    src.path = path;

    lex_entire_file(lexer, src);

    return src;
}
destroy_lex_file :: proc(src : ^Source_File) {
    delete(src.content);
    delete(src.lines);
}

Source_Location :: struct {
    src        : Source_File,
    line_num   : int,
    line_start : int,
    line_pos   : int,
    end_pos    : int,
    pos        : int,
    count      : int,
}
Token :: struct {
    name       : string,
    kind       : Token_Kind,
    literal    : Literal_Value,
    is_literal : bool,
    src_loc    : Source_Location,
}
tprint_token :: proc(using token: ^Token) -> string {

    context.allocator = context.temp_allocator;

    builder : strings.Builder;
    strings.builder_init(&builder);

    fmt.sbprintf(&builder, "(%s:%i): ", src_loc.src.path, src_loc.line_num);

    prefix_len := len(strings.to_string(builder));

    line := src_loc.src.lines[src_loc.line_num-1];
    word := src_loc.src.content[src_loc.pos:src_loc.end_pos];

    strings.write_string(&builder, fmt.tprintf("%s [%s", line, kind));
    if token.is_literal {
        strings.write_string(&builder, ": ");
        strings.write_string(&builder, fmt.tprint(token.literal));
    }
    strings.write_string(&builder, "]\n");
    
    for i in 0..<src_loc.line_pos + prefix_len {
        strings.write_string(&builder, " ");
    }
    for i in 0..<len(word) {
        strings.write_string(&builder, "^");
    }
    strings.write_string(&builder, "\n");
    
    
    return strings.to_string(builder);
}


GLSL_PARSER_TOKEN_BUCKET_SIZE :: 512
Token_Bucket :: utils.Bucket_Array(Token, GLSL_PARSER_TOKEN_BUCKET_SIZE)
Lexer :: struct {
    src_file    : ^Source_File,
    tokens      : Token_Bucket, 
    token_pos   : int,

    eat : proc(using lexer: ^Lexer) -> (token:^Token),
    peek :  proc(using lexer: ^Lexer, lookahead:= 0) -> (token:^Token),
}
make_lexer :: proc() -> Lexer {
    lexer : Lexer;
    using lexer;
    eat = lexer_eat;
    peek = lexer_peek;
    token_pos = 0;

    tokens = utils.make_bucket_array(Token, GLSL_PARSER_TOKEN_BUCKET_SIZE);

    return lexer;
}
destroy_lexer :: proc(using lexer : ^Lexer) {
    utils.delete_bucket_array(&tokens);
}

finish_token :: proc(token: ^Token, start_pos: int, name: string, kind: Token_Kind, loc: ^Source_Location, lit: Literal_Value = 0) {
    token.name = name;
    token.kind = kind;
    token.src_loc = loc^;
    token.literal = lit;
    token.src_loc.count = loc.pos - start_pos;
    token.src_loc.line_pos = loc.pos - token.src_loc.count - token.src_loc.line_start;
    token.src_loc.end_pos = loc.pos;
    token.src_loc.pos = start_pos;
    token.is_literal = kind == .LITERAL_F32 || kind == .LITERAL_F64 || kind == .LITERAL_INT || kind == .LITERAL_STRING;
}

consume_integral :: proc(using loc: ^Source_Location) -> int {
    first:= src.content[pos];

    assert(is_digit(first));

    word: string = src.content[pos:pos+1];

    next_pos:= pos+1;

    for is_digit(src.content[next_pos]) {
        word = src.content[pos:next_pos];
        next_pos += 1;
    }

    pos = next_pos;
        
    return strconv.atoi(word);
}
consume_espace_sequence :: proc(using loc: ^Source_Location) -> int{
    first:= src.content[pos];

    assert(first == '\\');

    next:= src.content[pos+1]
    if is_digit(next) {
        return consume_integral(loc);
    }

    pos = pos + 1;

    switch next {
        case 'a':  return 7;
        case 'b':  return 8;
        case 'f':  return 12;
        case 'n':  return 10;
        case 'r':  return 13;
        case 't':  return 9;
        case 'v':  return 11;
        case '\\': return 92;
        case '\'': return 39;
        case '\"': return 34;
        case: return int(src.content[pos]);
    }
}
maybe_lex_literal :: proc(using loc: ^Source_Location, token: ^Token) -> bool {
    start_pos:= pos;
    first:= src.content[pos];
    
    if pos+1 < len(src.content) && first == '\'' {
        next:= src.content[pos+1];
        lit_char := 0;
        if next == '\\' do lit_char = consume_espace_sequence(loc);
        else            do lit_char = int(next);

        pos += 1;
        finish_token(token, start_pos, src.content[start_pos:pos], .LITERAL_INT, loc, lit_char);
        return true;
    }

    if pos+1 < len(src.content) && first == '"' {
        next:= src.content[pos+1];
        closing_index := pos + 1 + strings.index(src.content[pos+1:], "\"");

        if closing_index == -1 do closing_index = len(src.content)-1;

        lit:= src.content[pos+1:closing_index-1];
        pos = closing_index+1;
        finish_token(token, start_pos, lit, .LITERAL_STRING, loc, lit);
        
        return true;
    }

    if first != '.' && !is_digit(first) do return false;

    numeric_word : string;
    has_dot      := false;    
    if first == '.' {
        has_dot = true;
        pos += 1;
    }
    next_pos     := pos;

    for next_pos < len(src.content) && is_digit(src.content[next_pos]) || src.content[next_pos] == '.' {
        if src.content[next_pos] == '.' {
            if has_dot do break;
            has_dot = true;
        }
        next_pos += 1;
    }
    numeric_word = src.content[pos:next_pos];

    is_f64 := src.content[next_pos] == 'd';
    if is_f64 do next_pos += 1;

    pos = next_pos;
    if has_dot do finish_token(token, start_pos, numeric_word, .LITERAL_F64 if is_f64 else .LITERAL_F32, loc, strconv.atof(numeric_word));
    else       do finish_token(token, start_pos, numeric_word, .LITERAL_INT, loc, strconv.atoi(numeric_word));


    return true;
}
maybe_lex_punctuation :: proc(using loc: ^Source_Location, token: ^Token) -> bool {
    if is_alpha(src.content[pos]) || is_digit(src.content[pos]) do return false;
    
    
    start_pos := pos;

    if is_single_punctuation(src.content[pos]) {
        str := src.content[pos:pos+1];
        pos += 1;
        finish_token(token, start_pos, str, Token_Kind(src.content[pos-1]), loc);
        return true;
    }

    if pos + 2 >= len(src.content) do return false;

    dbl := src.content[pos:pos+2];
    success, kind := try_punctuation(dbl);
    if success {
        pos += 2;
        finish_token(token, start_pos, dbl, kind, loc);
        return true;
    }

    if pos + 3 >= len(src.content) do return false;

    trp := src.content[pos:pos+3];
    success, kind = try_punctuation(trp);
    if success {
        pos += 2;
        finish_token(token, start_pos, trp, kind, loc);
        return true;
    }

    return false;
}

consume_next_word :: proc(using loc: ^Source_Location) -> string {
    first := src.content[pos];

    if (!is_alpha(first)) do return "";

    word: string = src.content[pos:pos+1];
    next_pos := pos + 1;

    if next_pos >= len(src.content) do return "";

    for next_pos < len(src.content) && is_alpha(src.content[next_pos]) || is_digit(src.content[next_pos]) || src.content[next_pos] == '_' {
        word = src.content[pos:next_pos];
        next_pos += 1;
    }

    word = src.content[pos:next_pos];
    pos = next_pos;

    return word;
}
lex_keyword_or_identifier :: proc(using loc: ^Source_Location, start_pos: int, token: ^Token, name: string) {
    is_keyword, kind := try_keyword(name);

    if (is_keyword) do finish_token(token, start_pos, name, kind, loc);
    else            do finish_token(token, start_pos, name, .IDENTIFIER, loc);
}
increment_line :: proc(using loc: ^Source_Location) {
    line_start = pos+1;
    line_num += 1;
}
consume_whitespace :: proc(using loc: ^Source_Location) {
    using src;
    for pos < len(content) && (is_whitespace(content[pos])) {
        if content[pos] == '\n' do increment_line(loc);
        pos += 1;
    }
}
consume_block_comment :: proc(using loc: ^Source_Location) {
    using src;
    
    if pos+2 >= len(content) {
        pos = len(content);
        return;
    }

    for pos+2 < len(content) && content[pos:pos+2] != "*/" {        
        if content[pos] == '\n' do increment_line(loc);
        pos += 1;

        if content[pos:pos+2] == "/*" do consume_block_comment(loc);
    }
    if content[pos:pos+2] == "*/" do pos += 2;
}
lex_entire_file :: proc(using lexer: ^Lexer, src: Source_File) {
    loc : Source_Location;
    loc.src = src;
    loc.pos = 0;
    loc.line_num = 1;

    main_loop: for loc.pos < len(loc.src.content) {
        consume_whitespace(&loc);

        using loc;
        using src;

        for pos+1 < len(content) && content[pos] == '/' {
            if content[pos+1] == '/' {
                for pos < len(content) && content[pos] != '\n' do pos += 1;
                if pos >= len(content) do break;
            } else if content[pos+1] == '*' {
                consume_block_comment(&loc);
            } else do break;

            if pos < len(content) do consume_whitespace(&loc);
            else do break main_loop;
        }

        
        if pos >= len(content) do break;
        token : Token;
        if maybe_lex_literal(&loc, &token) {
            utils.bucket_array_append(&tokens, token);
            continue;
        }
        
        
        if maybe_lex_punctuation(&loc, &token) {
            utils.bucket_array_append(&tokens, token);
            continue;
        }

        pos_before_word := loc.pos;
        word := consume_next_word(&loc);

        if (len(word) > 0) {
            lex_keyword_or_identifier(&loc, pos_before_word, &token, word);
            utils.bucket_array_append(&tokens, token);
            continue;
        }

        loc.pos += 1;
        finish_token(&token, pos-1, "<N/A>", .UNKNOWN, &loc);
        utils.bucket_array_append(&tokens, token);
    }
}

lexer_eat :: proc(using lexer: ^Lexer) -> (token:^Token) {
    if utils.bucket_array_len(tokens) < token_pos + 1 do return nil;
    token_pos += 1;
    return utils.bucket_array_get_ptr(&tokens, token_pos - 1);
}
lexer_peek :: proc(using lexer: ^Lexer, lookahead:= 0) -> (token:^Token) {
    look_pos := token_pos + lookahead;
    if (look_pos >= utils.bucket_array_len(tokens)) do return nil;
    if (look_pos < 0) do return nil;
    return utils.bucket_array_get_ptr(&tokens, look_pos);
}

is_whitespace :: proc(r : u8) -> bool{
    return r == ' ' || r == '\n';
}

is_digit :: proc(r : u8) -> bool {
    return (r >= '0' && r <= '9');
}

is_alpha :: proc(r : u8) -> bool {
    return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z');
}