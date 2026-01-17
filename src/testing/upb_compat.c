// Compatibility shim for upb amalgamation build.
// Provides symbols expected by generated upb code when using amalgamation.

// Don't include upb.h here to avoid redefinition of inline function.
// Just forward declare what we need.

struct upb_MiniTable;

// This function is used by generated map accessors to ensure the MiniTable is linked.
// It's defined as UPB_INLINE in the upb headers, but when compiling generated code
// separately from the amalgamation, the inline may not be emitted.
// This provides an out-of-line fallback with weak linkage.
__attribute__((weak))
const struct upb_MiniTable* _upb_MiniTable_StrongReference_dont_copy_me__upb_internal_use_only(
    const struct upb_MiniTable* mt) {
#if defined(__GNUC__)
  __asm__("" : : "r"(mt));
#else
  const struct upb_MiniTable* volatile unused = mt;
  (void)&unused;
#endif
  return mt;
}
