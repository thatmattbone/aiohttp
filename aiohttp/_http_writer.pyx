from libc.stdint cimport uint8_t, uint64_t
from libc.string cimport memcpy
from cpython.exc cimport PyErr_NoMemory
from cpython.mem cimport PyMem_Malloc, PyMem_Realloc, PyMem_Free

from cpython.bytes cimport PyBytes_FromStringAndSize


DEF BUF_SIZE = 16 * 1024  # 16KiB
cdef char BUFFER[BUF_SIZE]


# ----------------- writer ---------------------------

cdef struct Writer:
    char *buf
    Py_ssize_t size
    Py_ssize_t pos


cdef inline void _init_writer(Writer* writer):
    writer.buf = &BUFFER[0]
    writer.size = BUF_SIZE
    writer.pos = 0


cdef inline void _release_writer(Writer* writer):
    if writer.buf != BUFFER:
        PyMem_Free(writer.buf)


cdef inline int _write_byte(Writer* writer, uint8_t ch):
    cdef char * buf
    cdef Py_ssize_t size

    if writer.pos == writer.size:
        # reallocate
        size = writer.size + BUF_SIZE
        if writer.buf == BUFFER:
            buf = <char*>PyMem_Malloc(size)
            if buf == NULL:
                PyErr_NoMemory()
                return -1
            memcpy(buf, writer.buf, writer.size)
        else:
            buf = <char*>PyMem_Realloc(writer.buf, size)
            if buf == NULL:
                PyErr_NoMemory()
                return -1
        writer.buf = buf
        writer.size = size
    writer.buf[writer.pos] = <char>ch
    writer.pos += 1
    return 0


cdef inline int _write_utf8(Writer* writer, Py_UCS4 symbol):
    cdef uint64_t utf = <uint64_t> symbol

    if utf < 0x80:
        return _write_byte(writer, <uint8_t>utf)
    elif utf < 0x800:
        if _write_byte(writer, <uint8_t>(0xc0 | (utf >> 6))) < 0:
            return -1
        return _write_byte(writer,  <uint8_t>(0x80 | (utf & 0x3f)))
    elif 0xD800 <= utf <= 0xDFFF:
        # surogate pair, ignored
        return 0
    elif utf < 0x10000:
        if _write_byte(writer, <uint8_t>(0xe0 | (utf >> 12))) < 0:
            return -1
        if _write_byte(writer, <uint8_t>(0x80 | ((utf >> 6) & 0x3f))) < 0:
            return -1
        return _write_byte(writer, <uint8_t>(0x80 | (utf & 0x3f)))
    elif utf > 0x10FFFF:
        # symbol is too large
        return 0
    else:
        if _write_byte(writer,  <uint8_t>(0xf0 | (utf >> 18))) < 0:
            return -1
        if _write_byte(writer,
                       <uint8_t>(0x80 | ((utf >> 12) & 0x3f))) < 0:
           return -1
        if _write_byte(writer,
                       <uint8_t>(0x80 | ((utf >> 6) & 0x3f))) < 0:
            return -1
        return _write_byte(writer, <uint8_t>(0x80 | (utf & 0x3f)))


cdef inline int _write_str(Writer* writer, str s):
    cdef Py_UCS4 ch
    for ch in s:
        if _write_utf8(writer, ch) < 0:
            return -1


# --------------- _serialize_headers ----------------------

def _serialize_headers(str status_line, headers):
    cdef Writer writer
    cdef str key
    cdef str val
    cdef bytes ret

    _init_writer(&writer)

    try:
        if _write_str(&writer, status_line) < 0:
            raise
        if _write_byte(&writer, '\r') < 0:
            raise
        if _write_byte(&writer, '\n') < 0:
            raise

        for key, val in headers.items():
            if _write_str(&writer, key) < 0:
                raise
            if _write_byte(&writer, ':') < 0:
                raise
            if _write_byte(&writer, ' ') < 0:
                raise
            if _write_str(&writer, val) < 0:
                raise
            if _write_byte(&writer, '\r') < 0:
                raise
            if _write_byte(&writer, '\n') < 0:
                raise

        if _write_byte(&writer, '\r') < 0:
            raise
        if _write_byte(&writer, '\n') < 0:
            raise

        return PyBytes_FromStringAndSize(writer.buf, writer.pos)
    finally:
        _release_writer(&writer)