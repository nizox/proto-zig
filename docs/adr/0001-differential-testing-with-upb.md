# ADR-0001: Differential Testing with upb

## Status

Proposed

## Context

proto-zig aims to be compatible with the protobuf binary format. While we have conformance tests (97% passing), we lack direct comparison against a reference implementation for arbitrary inputs.

upb (micro protobuf) is the reference implementation that inspired proto-zig's design. Differential testing against upb would:

- Catch subtle encoding/decoding differences
- Validate our MiniTable layout matches upb's expectations

## Decision

Introduce differential testing that runs both proto-zig and upb on the same inputs and compares results.

### Components Modified

- **Build system**: Add upb as C dependency via Zig's C interop

### Architecture

```
                    ┌─────────────┐
                    │ Test Input  │
                    │ (binary pb) │
                    └──────┬──────┘
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
    ┌──────────────────┐     ┌──────────────────┐
    │    proto-zig     │     │       upb        │
    │  (native Zig)    │     │   (C via FFI)    │
    └────────┬─────────┘     └────────┬─────────┘
             │                        │
             ▼                        ▼
    ┌──────────────────┐     ┌──────────────────┐
    │  Decoded Message │     │  Decoded Message │
    │   + Re-encoded   │     │   + Re-encoded   │
    └────────┬─────────┘     └────────┬─────────┘
             │                        │
             └────────────┬───────────┘
                          ▼
                 ┌─────────────────┐
                 │    Comparator   │
                 │ (field-by-field)│
                 └─────────────────┘
```

### Test Strategy

1. **Decode comparison**: Both decode same binary, compare field values
2. **Roundtrip comparison**: Decode → Encode with both, compare output bytes
3. **Error agreement**: Both should fail/succeed on same inputs

### upb Integration

Use Zig's `@cImport` to call upb C functions:

```zig
const upb = @cImport({
    @cInclude("upb/mem/arena.h");
    @cInclude("upb/message/message.h");
    @cInclude("upb/wire/decode.h");
    @cInclude("upb/wire/encode.h");
});
```

Key upb functions:
- `upb_Arena_New()` / `upb_Arena_Free()` - memory management
- `upb_Message_New()` - create message from MiniTable
- `upb_Decode()` - decode binary to message
- `upb_Encode()` - encode message to binary

### Schema Compatibility

For differential testing to work, both implementations need compatible MiniTable definitions. Options:

1. **Generate from .proto**: Use protoc to generate both upb and proto-zig tables
2. **Hand-craft test schema**: Simple schema with all field types for testing
3. **Use conformance schema**: test_messages_proto3.proto already has upb tables

Recommended: Start with conformance schema (option 3) since upb tables already exist.

### Build Integration

```bash
zig build test-differential  # Run differential tests
```

## Consequences

### Positive

- High confidence in compatibility with reference implementation
- Documents exact behavioral differences (if any)

### Negative

- Build complexity: requires upb C library
- Test runtime increases due to FFI overhead
- Must keep upb version in sync

### Risks

- upb internal structures may change between versions
- Some intentional differences (e.g., validation strictness) need allowlisting

## Implementation Plan

1. Add upb as build dependency (link C library)
2. Create C interop wrapper in `src/testing/upb_ffi.zig`
3. Implement field-by-field comparator
4. Add differential decode test with conformance schema
6. Document any allowed differences

## References

- upb source: `/home/bits/gh/google/protobuf/upb/`
- upb decode API: `upb/wire/decode.h`
- upb encode API: `upb/wire/encode.h`
- Conformance proto: `protobuf/src/google/protobuf/test_messages_proto3.proto`
