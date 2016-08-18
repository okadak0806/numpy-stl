
from libc.stdio cimport *                                                                
from libc.string cimport memcpy, strcmp, strstr, strcpy

IF UNAME_SYSNAME == u"Windows":
    cdef extern from "io.h":
        int dup(int fd)
ELSE:
    cdef extern from "unistd.h":
        int dup(int fd)

import numpy as np
cimport numpy as np

np.import_array()

cdef packed struct Facet:
    np.float32_t n[3]
    np.float32_t v[3][3]
    np.uint16_t attr

dtype = np.dtype([
        ('normals', np.float32, 3),
        ('vectors', np.float32, (3, 3)),
        ('attr', np.uint16, 1),
    ])

DEF ALLOC_SIZE = 200000
DEF BUF_SIZE = 8192
DEF LINE_SIZE = 1024

cdef struct s_State:
    FILE* fp
    char buf[BUF_SIZE]
    char line[LINE_SIZE]
    size_t pos
    size_t size
    size_t line_num
    int recoverable

ctypedef s_State State

cdef char* readline(State* state) except NULL:

    cdef size_t line_pos = 0
    cdef char current;
    while True:
        if state.pos == state.size:

            if feof(state.fp):
                if line_pos != 0:
                    state.line[line_pos] = '\0'
                    return state.line
                raise RuntimeError(state.recoverable,
                    "Unexpected EOF")

            state.size = fread(state.buf, 1, BUF_SIZE, state.fp)
            state.pos = 0
            state.recoverable = 0

        current = state.buf[state.pos]
        state.pos += 1

        if line_pos != 0 or (current != ' ' \
                and current != '\t' \
                and current != '\r'):
            if current == '\n':
                state.line_num += 1
                if line_pos != 0:
                    state.line[line_pos] = '\0'
                    return state.line
            else:
                state.line[line_pos] = current
                line_pos += 1


def read(fh, buf):
    cdef char* line
    cdef char name[LINE_SIZE]
    cdef np.ndarray[Facet, cast=True] arr = np.zeros(ALLOC_SIZE, dtype = dtype)
    cdef size_t offset;
    cdef Facet* facet = <Facet*>arr.data
    cdef size_t pos = 0
    cdef State state 

    try:
        state.size = len(buf)
        memcpy(state.buf, <char*> buf, state.size)
        state.pos = 0
        state.line_num = 0
        state.recoverable = 1
        state.fp = fdopen(dup(fh.fileno()), 'rb')
        fseek(state.fp, fh.tell(), SEEK_SET)

        line = readline(&state)
        if strstr(line, "solid") == NULL \
                and strstr(line, "SOLID") == NULL:
            raise RuntimeError(state.recoverable,
                    "Solid name not found (%i:%s)" % (state.line_num, line))

        strcpy(name, line+5)

        while True:

            line = readline(&state)

            if strstr(line, "ENDSOLID") != NULL or \
                    strstr(line, "endsolid") != NULL:
                arr.resize(facet - <Facet*>arr.data, refcheck=False)
                return (<object>name).strip(), arr

            if strcmp(line, "COLOR") == 0 or \
                    strcmp(line, "color") == 0:
                readline(&state)
            elif sscanf(line, "%*s %*s %f %f %f",
                    facet.n, facet.n+1, facet.n+2) != 3:
                raise RuntimeError(state.recoverable,
                    "Can't read normals (%i:%s)" % (state.line_num, line))

            readline(&state) # outer loop

            for i in range(3):
                line = readline(&state)
                if sscanf(line, "%*s %f %f %f\n",
                        facet.v[i], facet.v[i]+1, facet.v[i]+2) != 3:
                    raise RuntimeError(state.recoverable,
                        "Can't read vertex (%i:%s)" % (state.line_num, line))

            readline(&state) # endloop
            readline(&state) # endfacet

            facet += 1
            offset = facet - <Facet*>arr.data
            if arr.shape[0] == offset:
                arr.resize(arr.shape[0] + ALLOC_SIZE, refcheck=False)
                facet = <Facet*>arr.data + offset

    finally:
        if state.recoverable == 0:
            pos = ftell(state.fp) - state.size + state.pos
            fclose(state.fp)
            fh.seek(pos, SEEK_SET)

def write(fh, name, np.ndarray[Facet, mode = 'c', cast=True] arr):
    cdef FILE* fp
    cdef Facet* facet = <Facet*>arr.data
    cdef Facet* end = <Facet*>arr.data + arr.shape[0]
    cdef size_t pos = 0
    
    try:
        fp = fdopen(dup(fh.fileno()), 'wb')
        fseek(fp, fh.tell(), SEEK_SET)
        fprintf(fp, 'solid %s\n', <char*>name)
        while facet != end:
            fprintf(fp, 
                "facet normal %f %f %f\n"
                "  outer loop\n"
                "    vertex %f %f %f\n"
                "    vertex %f %f %f\n"
                "    vertex %f %f %f\n"
                "  endloop\n"
                "endfacet\n",
                facet.n[0], facet.n[1], facet.n[2],
                facet.v[0][0], facet.v[0][1], facet.v[0][2],
                facet.v[1][0], facet.v[1][1], facet.v[1][2],
                facet.v[2][0], facet.v[2][1], facet.v[2][2])
            facet += 1
        fprintf(fp, 'endsolid %s\n', <char*>name)
    finally:
        pos = ftell(fp)
        fclose(fp)
        fh.seek(pos, SEEK_SET)
        