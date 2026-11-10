/* ELE portable runtime for generated C11 programs.
 * Experimental bootstrap backend: NOT a replacement for Stage 1 ownership
 * verification. Stage 1 must validate borrowing and drops before emission.
 * Public domain style project-local implementation, no Rust dependencies.
 */
#ifndef ELE_PORTABLE_RUNTIME_H
#define ELE_PORTABLE_RUNTIME_H
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#if defined(__GNUC__) || defined(__clang__)
#define ELE_UNUSED __attribute__((unused))
#else
#define ELE_UNUSED
#endif

typedef enum {
    ELE_UNSET, ELE_INT, ELE_BOOL, ELE_UNIT, ELE_TEXT, ELE_STRUCT,
    ELE_LIST, ELE_REF
} EleTag;
typedef struct EleValue EleValue;
struct EleValue {
    EleTag tag;
    union {
        int64_t i;
        bool b;
        struct { char *data; size_t len, cap; } text;
        struct { EleValue *data; size_t len; size_t type_id; } obj;
        struct { EleValue *data; size_t len, cap; size_t type_id; } list;
        EleValue *ref;
    } as;
};
static int ele_argc = 0;
static char **ele_argv = NULL;
static ELE_UNUSED inline void ele_die(const char *message) {
    fprintf(stderr, "ELE portable runtime: %s\n", message);
    exit(1);
}
static ELE_UNUSED inline void *ele_malloc(size_t n) {
    void *p = malloc(n ? n : 1);
    if (!p) ele_die("out of memory");
    return p;
}
static ELE_UNUSED inline void *ele_realloc(void *p, size_t n) {
    void *q = realloc(p, n ? n : 1);
    if (!q) ele_die("out of memory");
    return q;
}
static ELE_UNUSED inline EleValue ele_nil(void) { return (EleValue){.tag=ELE_UNSET}; }
static ELE_UNUSED inline EleValue ele_int(int64_t n) { return (EleValue){.tag=ELE_INT,.as.i=n}; }
static ELE_UNUSED inline EleValue ele_bool(bool b) { return (EleValue){.tag=ELE_BOOL,.as.b=b}; }
static ELE_UNUSED inline EleValue ele_unit(void) { return (EleValue){.tag=ELE_UNIT}; }
static ELE_UNUSED inline int64_t ele_as_int(const EleValue *v) {
    if (v->tag != ELE_INT) ele_die("expected live Int");
    return v->as.i;
}
static ELE_UNUSED inline bool ele_as_bool(const EleValue *v) {
    if (v->tag != ELE_BOOL) ele_die("expected live Bool");
    return v->as.b;
}
static ELE_UNUSED inline EleValue *ele_deref(EleValue *v) {
    if (v->tag == ELE_REF) {
        if (!v->as.ref) ele_die("null reference");
        return v->as.ref;
    }
    if (v->tag == ELE_UNSET) ele_die("use of uninitialized/moved value");
    return v;
}
static ELE_UNUSED inline EleValue ele_borrow(EleValue *v) {
    return (EleValue){.tag=ELE_REF,.as.ref=ele_deref(v)};
}
static ELE_UNUSED inline EleValue ele_take(EleValue *v) {
    if (v->tag == ELE_UNSET) ele_die("use after move");
    if (v->tag == ELE_REF) ele_die("cannot move reference as owning value");
    EleValue out = *v;
    if (v->tag == ELE_TEXT || v->tag == ELE_STRUCT || v->tag == ELE_LIST) {
        *v = ele_nil();
    }
    return out;
}
static ELE_UNUSED inline EleValue ele_copy(EleValue *v) {
    if (v->tag != ELE_INT && v->tag != ELE_BOOL && v->tag != ELE_UNIT)
        ele_die("attempt to copy an owned resource");
    return *v;
}
static ELE_UNUSED inline void ele_drop(EleValue *v) {
    if (v->tag == ELE_TEXT) free(v->as.text.data);
    else if (v->tag == ELE_STRUCT) {
        for (size_t i=v->as.obj.len;i>0;i--) ele_drop(&v->as.obj.data[i-1]);
        free(v->as.obj.data);
    } else if (v->tag == ELE_LIST) {
        for (size_t i=v->as.list.len;i>0;i--) ele_drop(&v->as.list.data[i-1]);
        free(v->as.list.data);
    }
    *v = ele_nil();
}
static ELE_UNUSED inline void ele_assign(EleValue *dest, EleValue item) {
    ele_drop(dest);
    *dest = item;
}
static ELE_UNUSED inline EleValue ele_text(const unsigned char *bytes, size_t size) {
    EleValue v = {.tag=ELE_TEXT};
    if (size > SIZE_MAX-1) ele_die("text too large");
    v.as.text.data = ele_malloc(size+1);
    if (size) memcpy(v.as.text.data, bytes, size);
    v.as.text.data[size] = 0;
    v.as.text.len = size;
    v.as.text.cap = size;
    return v;
}
static ELE_UNUSED inline EleValue ele_textbuf(size_t size) {
    EleValue v = {.tag=ELE_TEXT};
    if (size > SIZE_MAX-1) ele_die("text too large");
    v.as.text.data = ele_malloc(size+1);
    v.as.text.data[0] = 0;
    v.as.text.cap = size;
    return v;
}
static ELE_UNUSED inline void ele_text_append(EleValue *v, const char *text, size_t size) {
    v = ele_deref(v);
    if (v->tag != ELE_TEXT) ele_die("append on non-Text");
    if (size > SIZE_MAX-v->as.text.len-1) ele_die("text length overflow");
    size_t need = v->as.text.len+size;
    if (need > v->as.text.cap) {
        size_t cap = v->as.text.cap ? v->as.text.cap : 16;
        while (cap < need) {
            if (cap > SIZE_MAX/2) { cap=need; break; }
            cap*=2;
        }
        v->as.text.data = ele_realloc(v->as.text.data,cap+1);
        v->as.text.cap=cap;
    }
    if (size) memcpy(v->as.text.data+v->as.text.len,text,size);
    v->as.text.len=need;
    v->as.text.data[need]=0;
}
static ELE_UNUSED inline void ele_format(EleValue *buffer, const EleValue *v) {
    char temp[64];
    switch (v->tag) {
    case ELE_INT: {
        int n=snprintf(temp,sizeof(temp),"%" PRId64,v->as.i);
        if (n<0) ele_die("integer format failure");
        ele_text_append(buffer,temp,(size_t)n); break;
    }
    case ELE_BOOL: {
        const char *s=v->as.b?"true":"false";
        ele_text_append(buffer,s,strlen(s)); break;
    }
    case ELE_UNIT: ele_text_append(buffer,"()",2); break;
    case ELE_TEXT: ele_text_append(buffer,v->as.text.data,v->as.text.len); break;
    default: ele_die("unsupported format value");
    }
}
static ELE_UNUSED inline void ele_append(EleValue *buf, EleValue *arg, bool consumed) {
    EleValue *p=ele_deref(arg);
    ele_format(buf,p);
    if (consumed) ele_drop(arg);
}
static ELE_UNUSED inline void ele_print(const EleValue *p, FILE *f) {
    switch(p->tag) {
    case ELE_INT: fprintf(f,"%" PRId64,p->as.i); break;
    case ELE_BOOL: fputs(p->as.b?"true":"false",f); break;
    case ELE_UNIT: fputs("()",f); break;
    case ELE_TEXT:
        if(p->as.text.len && fwrite(p->as.text.data,1,p->as.text.len,f)!=p->as.text.len)
            ele_die("write failure");
        break;
    default: ele_die("unsupported print value");
    }
    fputc('\n',f);
}
static ELE_UNUSED inline void ele_print_arg(EleValue *p, bool consumed, bool err) {
    ele_print(ele_deref(p),err?stderr:stdout);
    if (consumed) ele_drop(p);
}
static ELE_UNUSED inline EleValue ele_struct(size_t n, EleValue *fields, size_t type_id) {
    EleValue v={.tag=ELE_STRUCT};
    if(n>SIZE_MAX/sizeof(EleValue)) ele_die("too many struct fields");
    v.as.obj.data=ele_malloc((n?n:1)*sizeof(EleValue));
    if(n) memcpy(v.as.obj.data,fields,n*sizeof(EleValue));
    v.as.obj.len=n; v.as.obj.type_id=type_id;
    return v;
}
static ELE_UNUSED inline EleValue ele_list(size_t n, EleValue *items, size_t type_id) {
    EleValue v={.tag=ELE_LIST};
    if(n>SIZE_MAX/sizeof(EleValue)) ele_die("too many list elements");
    v.as.list.data=ele_malloc((n?n:1)*sizeof(EleValue));
    if(n) memcpy(v.as.list.data,items,n*sizeof(EleValue));
    v.as.list.len=n; v.as.list.cap=n; v.as.list.type_id=type_id;
    return v;
}
static ELE_UNUSED inline void ele_list_reserve(EleValue *p, int64_t additional) {
    p=ele_deref(p);
    if(p->tag!=ELE_LIST) ele_die("reserve on non-list");
    if(additional<0 || (uint64_t)additional>SIZE_MAX-p->as.list.len)
        ele_die("invalid list reserve");
    size_t need=p->as.list.len+(size_t)additional;
    if(need<=p->as.list.cap) return;
    size_t cap=p->as.list.cap?p->as.list.cap:4;
    while(cap<need) {
        if(cap>SIZE_MAX/2) {cap=need;break;}
        cap*=2;
    }
    if(cap>SIZE_MAX/sizeof(EleValue)) ele_die("list capacity overflow");
    p->as.list.data=ele_realloc(p->as.list.data,cap*sizeof(EleValue));
    p->as.list.cap=cap;
}
static ELE_UNUSED inline void ele_list_push(EleValue *p, EleValue item) {
    p=ele_deref(p);
    if(p->tag!=ELE_LIST) ele_die("push on non-list");
    ele_list_reserve(p,1);
    p->as.list.data[p->as.list.len++]=item;
}
static ELE_UNUSED inline EleValue *ele_field(EleValue *p, size_t index) {
    p=ele_deref(p);
    if(p->tag!=ELE_STRUCT||index>=p->as.obj.len) ele_die("field out of range");
    return &p->as.obj.data[index];
}
static ELE_UNUSED inline EleValue *ele_index(EleValue *p, int64_t index) {
    p=ele_deref(p);
    if(p->tag!=ELE_LIST||index<0||(uint64_t)index>=p->as.list.len)
        ele_die("index out of range");
    return &p->as.list.data[(size_t)index];
}
static ELE_UNUSED inline int64_t ele_len(EleValue *p) {
    p=ele_deref(p);
    size_t n=0;
    if(p->tag==ELE_TEXT) n=p->as.text.len;
    else if(p->tag==ELE_LIST) n=p->as.list.len;
    else ele_die("length of unsupported type");
    if(n>INT64_MAX) ele_die("length exceeds Int range");
    return (int64_t)n;
}
static ELE_UNUSED inline int64_t ele_cap(EleValue *p) {
    p=ele_deref(p);
    if(p->tag!=ELE_LIST) ele_die("capacity of non-list");
    if(p->as.list.cap>INT64_MAX) ele_die("capacity exceeds Int range");
    return (int64_t)p->as.list.cap;
}
static ELE_UNUSED inline int64_t ele_byte_at(EleValue *p, int64_t idx) {
    p=ele_deref(p);
    if(p->tag!=ELE_TEXT||idx<0||(uint64_t)idx>=p->as.text.len)
        ele_die("Text.byteAt index out of range");
    return (unsigned char)p->as.text.data[idx];
}
static ELE_UNUSED inline int64_t ele_iadd(int64_t a,int64_t b) {
    if((b>0 && a>INT64_MAX-b) || (b<0 && a<INT64_MIN-b))
        ele_die("integer overflow");
    return a+b;
}
static ELE_UNUSED inline int64_t ele_isub(int64_t a,int64_t b) {
    if((b<0 && a>INT64_MAX+b) || (b>0 && a<INT64_MIN+b))
        ele_die("integer overflow");
    return a-b;
}
static ELE_UNUSED inline int64_t ele_imul(int64_t a,int64_t b) {
    if(a==0 || b==0) return 0;
    if((a==-1 && b==INT64_MIN) || (b==-1 && a==INT64_MIN))
        ele_die("integer overflow");
    if(a>0) {
        if(b>0 && a>INT64_MAX/b) ele_die("integer overflow");
        if(b<0 && b<INT64_MIN/a) ele_die("integer overflow");
    } else {
        if(b>0 && a<INT64_MIN/b) ele_die("integer overflow");
        if(b<0 && a<INT64_MAX/b) ele_die("integer overflow");
    }
    return a*b;
}
static ELE_UNUSED inline int64_t ele_ineg(int64_t n) {
    if(n==INT64_MIN) ele_die("integer overflow");
    return -n;
}
static ELE_UNUSED inline int64_t ele_idiv(int64_t a,int64_t b) {
    if(b==0||(a==INT64_MIN&&b==-1)) ele_die("division by zero/overflow");
    return a/b;
}
static ELE_UNUSED inline int64_t ele_irem(int64_t a,int64_t b) {
    if(b==0||(a==INT64_MIN&&b==-1)) ele_die("division by zero/overflow");
    return a%b;
}
static ELE_UNUSED inline void ele_drop_locals(EleValue *vars,size_t n) {
    for(size_t i=n;i>0;i--) ele_drop(&vars[i-1]);
}
#endif
