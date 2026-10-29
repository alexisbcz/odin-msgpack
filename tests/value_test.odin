package msgpack_tests

import msgpack ".."
import "core:mem"
import "core:testing"

@(test)
test_decode_value_scalars :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	Case :: struct {
		input: []byte,
		want:  msgpack.Value,
	}
	cases := []Case {
		{{0xc0}, nil},
		{{0xc2}, false},
		{{0x05}, i64(5)},
		{{0xd0, 0xfe}, i64(-2)},
		{{0xcf, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, max(u64)},
		{{0xcf, 0, 0, 0, 0, 0, 0, 0, 9}, i64(9)},
		{{0xca, 0x3f, 0xc0, 0x00, 0x00}, f32(1.5)},
		{{0xcb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0}, f64(1.5)},
		{{0xd6, 0xff, 0, 0, 0, 7}, msgpack.Timestamp{7, 0}},
	}
	for c in cases {
		v, err := msgpack.decode_value(c.input, alloc)
		testing.expect_value(t, err, nil)
		testing.expectf(t, msgpack.value_equal(v, c.want), "input %x: got %v, want %v", c.input, v, c.want)
		msgpack.value_destroy(v, alloc)
	}
}

@(test)
test_decode_value_nested_document :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	// {"name": "odin", "tags": ["a", bin(0x01)], "ext": ext(3, 0xab)}
	input := []byte {
		0x83,
		0xa4, 'n', 'a', 'm', 'e', 0xa4, 'o', 'd', 'i', 'n',
		0xa4, 't', 'a', 'g', 's', 0x92, 0xa1, 'a', 0xc4, 0x01, 0x01,
		0xa3, 'e', 'x', 't', 0xd4, 0x03, 0xab,
	}
	v, err := msgpack.decode_value(input, alloc)
	defer msgpack.value_destroy(v, alloc)
	testing.expect_value(t, err, nil)

	m, is_map := v.(msgpack.Map)
	testing.expect(t, is_map, "top level must be a map")
	testing.expect_value(t, len(m), 3)

	name, found := msgpack.map_get(m, "name")
	testing.expect(t, found)
	testing.expect_value(t, name.(string), "odin")

	tags, _ := msgpack.map_get(m, "tags")
	arr := tags.(msgpack.Array)
	testing.expect_value(t, len(arr), 2)
	testing.expect_value(t, arr[0].(string), "a")
	testing.expect_value(t, len(arr[1].(msgpack.Binary)), 1)

	ext, _ := msgpack.map_get(m, "ext")
	x := ext.(msgpack.Extension)
	testing.expect_value(t, x.type, 3)
	testing.expect_value(t, x.data[0], 0xab)

	_, missing := msgpack.map_get(m, "nope")
	testing.expect(t, !missing)
}

@(test)
test_value_round_trip_is_byte_exact :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	input := []byte {
		0x93,
		0xcd, 0x01, 0x00,
		0x81, 0xa1, 'k', 0xd1, 0xff, 0x7f,
		0x92, 0xc3, 0xd7, 0xff, 0, 0, 0, 0x04, 0, 0, 0, 1,
	}
	v, err := msgpack.decode_value(input, alloc)
	defer msgpack.value_destroy(v, alloc)
	testing.expect_value(t, err, nil)

	out, eerr := msgpack.encode_value(v, alloc)
	defer delete(out, alloc)
	testing.expect_value(t, eerr, nil)
	expect_bytes(t, out, input)
}

@(test)
test_decode_value_rejects_trailing_data :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	v, err := msgpack.decode_value({0xa1, 'a', 0xc0}, alloc)
	testing.expect_value(t, err, decode_err(.Trailing_Data))
	testing.expect(t, v == nil)
}

@(test)
test_decode_value_failure_frees_partial_result :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	// An array of three strings whose last string is cut short.
	v, err := msgpack.decode_value({0x93, 0xa2, 'h', 'i', 0xa2, 'y', 'o', 0xa5, 'x'}, alloc)
	testing.expect_value(t, err, decode_err(.Unexpected_Eof))
	testing.expect(t, v == nil)
}

@(test)
test_decode_value_rejects_reserved_byte_inside_array :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	_, err := msgpack.decode_value({0x92, 0xa1, 'a', 0xc1}, alloc)
	testing.expect_value(t, err, decode_err(.Invalid_Format))
}

@(test)
test_decode_value_enforces_max_depth :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	nested: [64]byte
	for &b in nested {
		b = 0x91
	}
	nested[63] = 0xc0
	_, err := msgpack.decode_value(nested[:], alloc, max_depth = 16)
	testing.expect_value(t, err, decode_err(.Max_Depth_Exceeded))

	v, ok_err := msgpack.decode_value(nested[:], alloc, max_depth = 64)
	testing.expect_value(t, ok_err, nil)
	msgpack.value_destroy(v, alloc)
}

@(test)
test_read_value_streams_several_items :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	d: msgpack.Decoder
	msgpack.decoder_init(&d, {0x01, 0xa2, 'o', 'k', 0xc0})
	a, _ := msgpack.read_value(&d, alloc)
	b, _ := msgpack.read_value(&d, alloc)
	c, err := msgpack.read_value(&d, alloc)
	defer msgpack.value_destroy(b, alloc)
	testing.expect_value(t, err, nil)
	testing.expect(t, msgpack.value_equal(a, i64(1)))
	testing.expect_value(t, b.(string), "ok")
	testing.expect(t, c == nil)
	testing.expect_value(t, msgpack.decoder_remaining(&d), 0)
}

@(test)
test_encode_value_builds_document :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	alloc := track_begin(&track)
	defer track_end(t, &track)

	items := []msgpack.Value{i64(-1), "hi", msgpack.Binary{0x7f}, nil}
	entries := []msgpack.Map_Entry{{key = "list", value = msgpack.Array(items)}}
	out, err := msgpack.encode_value(msgpack.Map(entries), alloc)
	defer delete(out, alloc)
	testing.expect_value(t, err, nil)
	expect_bytes(t, out, {0x81, 0xa4, 'l', 'i', 's', 't', 0x94, 0xff, 0xa2, 'h', 'i', 0xc4, 0x01, 0x7f, 0xc0})
}
