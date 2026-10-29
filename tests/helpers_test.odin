// Package msgpack_tests holds the unit tests for msgpack. Run them with `odin test tests`.
package msgpack_tests

import msgpack ".."
import "base:runtime"
import "core:mem"
import "core:testing"

// track_begin wraps the context allocator in a tracking allocator for one test.
track_begin :: proc(track: ^mem.Tracking_Allocator) -> runtime.Allocator {
	mem.tracking_allocator_init(track, context.allocator)
	return mem.tracking_allocator(track)
}

// track_end fails the test if anything leaked or was freed badly, then releases the tracker.
track_end :: proc(t: ^testing.T, track: ^mem.Tracking_Allocator, loc := #caller_location) {
	for _, entry in track.allocation_map {
		testing.expectf(t, false, "leaked %d bytes allocated at %v", entry.size, entry.location, loc = loc)
	}
	for entry in track.bad_free_array {
		testing.expectf(t, false, "bad free of %p at %v", entry.memory, entry.location, loc = loc)
	}
	mem.tracking_allocator_destroy(track)
}

// expect_bytes compares encoded output with the bytes the specification prescribes.
expect_bytes :: proc(t: ^testing.T, got: []byte, want: []byte, loc := #caller_location) {
	if len(got) != len(want) {
		testing.expectf(t, false, "got %d bytes %x, want %d bytes %x", len(got), got, len(want), want, loc = loc)
		return
	}
	for i in 0 ..< len(got) {
		if got[i] != want[i] {
			testing.expectf(t, false, "byte %d: got %x, want %x (full: %x)", i, got[i], want[i], got, loc = loc)
			return
		}
	}
}

// decode_err builds a Decode_Error value comparable with procedure results.
decode_err :: proc(e: msgpack.Decode_Error) -> msgpack.Error {
	return e
}

// encode_err builds an Encode_Error value comparable with procedure results.
encode_err :: proc(e: msgpack.Encode_Error) -> msgpack.Error {
	return e
}
