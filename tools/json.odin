// JSON for the map tools: a writer that lays text out the way Python's
// json.dumps does (key order kept, its separators and indent), so files
// round-trip unchanged, and accessors over core:encoding/json values.
package tools

import "core:encoding/json"
import "core:fmt"
import "core:strings"

Json_Style :: enum {
	Compact, // separators (",", ":")
	Spaced,  // the default separators (", ", ": ")
	Indent1, // indent=1
}

Json_Writer :: struct {
	b:         strings.Builder,
	style:     Json_Style,
	depth:     int,
	first:     bool, // nothing written yet in the open container
	after_key: bool,
}

jw_make :: proc(style: Json_Style) -> Json_Writer {
	return {b = strings.builder_make(), style = style}
}

@(private = "file")
jw_newline :: proc(w: ^Json_Writer) {
	strings.write_byte(&w.b, '\n')
	for _ in 0 ..< w.depth {
		strings.write_byte(&w.b, ' ')
	}
}

// Starts a value: the separator before it and, indented, its line.
@(private = "file")
jw_item :: proc(w: ^Json_Writer) {
	if w.after_key {
		w.after_key = false
		return
	}
	if w.depth == 0 {
		return
	}
	if !w.first {
		strings.write_string(&w.b, w.style == .Spaced ? ", " : ",")
	}
	if w.style == .Indent1 {
		jw_newline(w)
	}
	w.first = false
}

jw_open :: proc(w: ^Json_Writer, bracket: u8) {
	jw_item(w)
	strings.write_byte(&w.b, bracket)
	w.depth += 1
	w.first = true
}

jw_close :: proc(w: ^Json_Writer, bracket: u8) {
	w.depth -= 1
	if !w.first && w.style == .Indent1 {
		jw_newline(w)
	}
	strings.write_byte(&w.b, bracket)
	w.first = false
}

jw_key :: proc(w: ^Json_Writer, key: string) {
	jw_item(w)
	fmt.sbprintf(&w.b, "\"%s\"", key)
	strings.write_string(&w.b, w.style == .Compact ? ":" : ": ")
	w.after_key = true
}

jw_int :: proc(w: ^Json_Writer, v: int) {
	jw_item(w)
	fmt.sbprintf(&w.b, "%d", v)
}

jw_string :: proc(w: ^Json_Writer, s: string) {
	jw_item(w)
	fmt.sbprintf(&w.b, "\"%s\"", s)
}

jw_ints :: proc(w: ^Json_Writer, vs: ..int) {
	jw_open(w, '[')
	for v in vs {
		jw_int(w, v)
	}
	jw_close(w, ']')
}

jw_field :: proc(w: ^Json_Writer, key: string, v: int) {
	jw_key(w, key)
	jw_int(w, v)
}

jw_bytes :: proc(w: ^Json_Writer) -> []u8 {
	return w.b.buf[:]
}

json_load :: proc(path: string) -> json.Value {
	return json_parse(path, read_file(path))
}

json_parse :: proc(path: string, text: []u8) -> json.Value {
	v, err := json.parse(text, parse_integers = true)
	if err != nil {
		fail("%s: %v", path, err)
	}
	return v
}

json_get :: proc(v: json.Value, key: string) -> (json.Value, bool) {
	obj, is_obj := v.(json.Object)
	if !is_obj {
		fail("not a JSON object (looking for %q)", key)
	}
	return obj[key]
}

json_at :: proc(v: json.Value, key: string) -> json.Value {
	x, ok := json_get(v, key)
	if !ok {
		fail("JSON object has no %q", key)
	}
	return x
}

json_int :: proc(v: json.Value) -> int {
	#partial switch x in v {
	case json.Integer:
		return int(x)
	case json.Float:
		return int(x)
	case json.Boolean:
		return int(x)
	}
	fail("not a JSON number: %v", v)
}

json_list :: proc(v: json.Value) -> json.Array {
	a, ok := v.(json.Array)
	if !ok {
		fail("not a JSON list: %v", v)
	}
	return a
}

json_str :: proc(v: json.Value) -> string {
	s, ok := v.(json.String)
	if !ok {
		fail("not a JSON string: %v", v)
	}
	return s
}

json_int_at :: proc(v: json.Value, key: string) -> int {
	return json_int(json_at(v, key))
}

json_list_at :: proc(v: json.Value, key: string) -> json.Array {
	return json_list(json_at(v, key))
}
