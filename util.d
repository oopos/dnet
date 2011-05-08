import std.traits: isDelegate, isIntegral;
import std.string: hexdigits;
import core.memory;

D scopeDelegate(D)(scope D d) if (isDelegate!D)
{
  return d;
}

T[] uninitializedArray(T)(size_t length)
{
  T* p = cast(T*) GC.malloc(length * T.sizeof,
    (typeid(T[]).next.flags & 1) ? 0 : GC.BlkAttr.NO_SCAN);
  return p[0..length];
}

string hex(T)(T n) if (isIntegral!T)
{
  auto h = new char[T.sizeof * 2];
  size_t pos = T.sizeof * 2;
  do {
    h[--pos] = hexdigits[n & 0xF];
  } while (n >>>= 4);
  return cast(string) h[pos..$];
}

unittest
{
  assert(hex(0x1B2C9F) == "1B2C9F");
  assert(hex(0) == "0");
  assert(hex(0xF) == "F");
  assert(hex!ubyte(0xFA) == "FA");
  assert(hex!ubyte(3) == "3");
  assert(hex(0x11223344AABBCCDD) == "11223344AABBCCDD");
}
