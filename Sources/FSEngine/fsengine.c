#include "fsengine.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <unistd.h>

#define BULK_BUF_SIZE (256 * 1024)

uint64_t fse_now_ns(void) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / tb.denom;
}

int fse_name_compare(const char *a, const char *b) {
    const unsigned char *p = (const unsigned char *)a, *q = (const unsigned char *)b;
    for (;;) {
        if (isdigit(*p) && isdigit(*q)) {
            while (*p == '0') p++;
            while (*q == '0') q++;
            const unsigned char *ps = p, *qs = q;
            while (isdigit(*p)) p++;
            while (isdigit(*q)) q++;
            if (p - ps != q - qs) return (p - ps) < (q - qs) ? -1 : 1;
            int c = memcmp(ps, qs, (size_t)(p - ps));
            if (c) return c;
            continue;
        }
        int ca = tolower(*p), cb = tolower(*q);
        if (ca != cb) return ca < cb ? -1 : 1;
        if (*p == 0) return strcmp(a, b);
        p++; q++;
    }
}

static int grow_entries(fse_dir *d) {
    uint32_t cap = d->cap ? d->cap * 2 : 256;
    fse_entry *e = realloc(d->entries, (size_t)cap * sizeof *e);
    if (!e) return ENOMEM;
    d->entries = e;
    d->cap = cap;
    return 0;
}

static int push(fse_dir *d, const char *name, uint32_t len, uint16_t flags, uint64_t size, int64_t mtime, int64_t added) {
    if (d->count == d->cap && grow_entries(d)) return ENOMEM;
    if (d->arena_len + len + 1 > d->arena_cap) {
        uint32_t cap = d->arena_cap ? d->arena_cap : 8192;
        while (d->arena_len + len + 1 > cap) cap *= 2;
        char *a = realloc(d->arena, cap);
        if (!a) return ENOMEM;
        d->arena = a;
        d->arena_cap = cap;
    }
    fse_entry *e = &d->entries[d->count++];
    e->name_off = d->arena_len;
    e->name_len = (uint16_t)len;
    e->flags = flags;
    e->size = size;
    e->mtime = mtime;
    e->added = added;
    memcpy(d->arena + d->arena_len, name, len);
    d->arena[d->arena_len + len] = 0;
    d->arena_len += len + 1;
    if (flags & FSE_DIR) d->dir_count++;
    return 0;
}

static int read_bulk(int fd, fse_dir *d, int include_hidden) {
    struct attrlist al;
    memset(&al, 0, sizeof al);
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE |
                    ATTR_CMN_MODTIME | ATTR_CMN_FLAGS | ATTR_CMN_ADDEDTIME;
    al.fileattr = ATTR_FILE_DATALENGTH;

    char *buf = malloc(BULK_BUF_SIZE);
    if (!buf) return ENOMEM;

    int rc = 0;
    for (;;) {
        int n = getattrlistbulk(fd, &al, buf, BULK_BUF_SIZE, 0);
        if (n < 0) { rc = errno; break; }
        if (n == 0) break;

        char *p = buf;
        for (int i = 0; i < n; i++) {
            char *rec = p;
            uint32_t reclen;
            memcpy(&reclen, rec, sizeof reclen);
            char *f = rec + sizeof(uint32_t);
            attribute_set_t ret;
            memcpy(&ret, f, sizeof ret);
            f += sizeof ret;

            const char *name = NULL;
            uint32_t namelen = 0;
            if (ret.commonattr & ATTR_CMN_NAME) {
                attrreference_t r;
                memcpy(&r, f, sizeof r);
                name = f + r.attr_dataoffset;
                namelen = r.attr_length;
                f += sizeof r;
            }
            fsobj_type_t type = VNON;
            if (ret.commonattr & ATTR_CMN_OBJTYPE) { memcpy(&type, f, sizeof type); f += sizeof type; }
            int64_t mtime = 0;
            if (ret.commonattr & ATTR_CMN_MODTIME) { struct timespec ts; memcpy(&ts, f, sizeof ts); mtime = ts.tv_sec; f += sizeof ts; }
            uint32_t bsdflags = 0;
            if (ret.commonattr & ATTR_CMN_FLAGS) { memcpy(&bsdflags, f, sizeof bsdflags); f += sizeof bsdflags; }
            int64_t added = 0;
            if (ret.commonattr & ATTR_CMN_ADDEDTIME) { struct timespec ts; memcpy(&ts, f, sizeof ts); added = ts.tv_sec; f += sizeof ts; }
            if (added == 0) added = mtime;
            uint64_t size = 0;
            if (ret.fileattr & ATTR_FILE_DATALENGTH) { off_t sz; memcpy(&sz, f, sizeof sz); size = (uint64_t)sz; f += sizeof sz; }
            p = rec + reclen;

            if (!name || namelen == 0) continue;
            if (name[namelen - 1] == 0) namelen--;
            if (namelen == 0 || namelen > UINT16_MAX) continue;

            uint16_t flags = 0;
            if (type == VDIR) flags |= FSE_DIR;
            if (type == VLNK) flags |= FSE_SYMLINK;
            if (name[0] == '.' || (bsdflags & UF_HIDDEN)) flags |= FSE_HIDDEN;
            if ((flags & FSE_HIDDEN) && !include_hidden) continue;

            if ((rc = push(d, name, namelen, flags, size, mtime, added))) goto out;
        }
    }
out:
    free(buf);
    return rc;
}

static int read_readdir(int fd, fse_dir *d, int include_hidden) {
    int dupfd = dup(fd);
    if (dupfd < 0) return errno;
    DIR *dir = fdopendir(dupfd);
    if (!dir) { int e = errno; close(dupfd); return e; }
    rewinddir(dir);
    struct dirent *de;
    int rc = 0;
    while ((de = readdir(dir))) {
        if (de->d_name[0] == '.' && (de->d_name[1] == 0 || (de->d_name[1] == '.' && de->d_name[2] == 0))) continue;
        struct stat st;
        if (fstatat(fd, de->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) continue;
        uint16_t flags = 0;
        if (S_ISDIR(st.st_mode)) flags |= FSE_DIR;
        if (S_ISLNK(st.st_mode)) flags |= FSE_SYMLINK;
        if (de->d_name[0] == '.' || (st.st_flags & UF_HIDDEN)) flags |= FSE_HIDDEN;
        if ((flags & FSE_HIDDEN) && !include_hidden) continue;
        uint32_t len = (uint32_t)strlen(de->d_name);
        if (len > UINT16_MAX) continue;
        if ((rc = push(d, de->d_name, len, flags, (uint64_t)st.st_size, st.st_mtimespec.tv_sec, st.st_birthtimespec.tv_sec))) break;
    }
    closedir(dir);
    return rc;
}

static int compare_entries(void *thunk, const void *pa, const void *pb) {
    const fse_dir *d = thunk;
    const fse_entry *a = pa, *b = pb;
    int da = (a->flags & FSE_DIR) != 0, db = (b->flags & FSE_DIR) != 0;
    if (da != db) return da ? -1 : 1;
    return fse_name_compare(d->arena + a->name_off, d->arena + b->name_off);
}

static int compare_added(void *thunk, const void *pa, const void *pb) {
    const fse_dir *d = thunk;
    const fse_entry *a = pa, *b = pb;
    int da = (a->flags & FSE_DIR) != 0, db = (b->flags & FSE_DIR) != 0;
    if (da != db) return da ? -1 : 1;
    if (a->added != b->added) return a->added > b->added ? -1 : 1;
    return fse_name_compare(d->arena + a->name_off, d->arena + b->name_off);
}

void fse_dir_sort_by(fse_dir *d, int sort) {
    if (d->count < 2) return;
    qsort_r(d->entries, d->count, sizeof *d->entries, d, sort == FSE_SORT_ADDED ? compare_added : compare_entries);
}

fse_dir *fse_dir_read(const char *path, const fse_options *opts, int *err) {
    int include_hidden = opts ? opts->include_hidden : 0;
    int sort = opts ? opts->sort : FSE_SORT_NAME;
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) { if (err) *err = errno; return NULL; }

    fse_dir *d = calloc(1, sizeof *d);
    if (!d) { close(fd); if (err) *err = ENOMEM; return NULL; }

    uint64_t t0 = fse_now_ns();
    int rc = read_bulk(fd, d, include_hidden);
    if (rc == ENOTSUP || rc == EINVAL) {
        d->count = d->dir_count = d->arena_len = 0;
        rc = read_readdir(fd, d, include_hidden);
    }
    close(fd);
    if (rc) { fse_dir_free(d); if (err) *err = rc; return NULL; }
    d->read_ns = fse_now_ns() - t0;

    t0 = fse_now_ns();
    fse_dir_sort_by(d, sort);
    d->sort_ns = fse_now_ns() - t0;
    if (err) *err = 0;
    return d;
}

fse_dir *fse_dir_new(void) {
    return calloc(1, sizeof(fse_dir));
}

int fse_dir_append(fse_dir *d, const char *name, uint16_t flags) {
    size_t len = strlen(name);
    if (len == 0 || len > UINT16_MAX) return EINVAL;
    return push(d, name, (uint32_t)len, flags, 0, 0, 0);
}

void fse_dir_sort(fse_dir *d) {
    if (d->count > 1) qsort_r(d->entries, d->count, sizeof *d->entries, d, compare_entries);
}

void fse_dir_free(fse_dir *d) {
    if (!d) return;
    free(d->entries);
    free(d->arena);
    free(d);
}

size_t fse_dir_memory(const fse_dir *d) {
    return sizeof *d + (size_t)d->cap * sizeof(fse_entry) + d->arena_cap;
}

static int is_separator(int c) {
    return c == ' ' || c == '-' || c == '_' || c == '.' || c == '/' || c == '(' || c == '[';
}

int32_t fse_fuzzy_score(const char *name, const char *query) {
    if (!*query) return 0;
    int32_t score = 0;
    int consecutive = 0, first = -1, prev = 0;
    size_t qi = 0, i = 0;
    for (; name[i] && query[qi]; i++) {
        int c = (unsigned char)name[i];
        if (tolower(c) == tolower((unsigned char)query[qi])) {
            int bonus = 2;
            if (i == 0) bonus += 16;
            else if (is_separator(prev)) bonus += 10;
            else if (islower(prev) && isupper(c)) bonus += 8;
            else if (isdigit(c) != isdigit(prev)) bonus += 4;
            if (consecutive) bonus += 6 + (consecutive < 4 ? consecutive : 4);
            if (c == (unsigned char)query[qi]) bonus += 1;
            score += bonus;
            consecutive++;
            qi++;
            if (first < 0) first = (int)i;
        } else {
            if (first >= 0) score -= 1;
            consecutive = 0;
        }
        prev = c;
    }
    if (query[qi]) return -1;
    if (!name[i] && i == qi) score += 20;
    score -= first > 10 ? 10 : first;
    return score < 0 ? 0 : score;
}

static int compare_matches(void *thunk, const void *pa, const void *pb) {
    const fse_dir *d = thunk;
    const fse_match *a = pa, *b = pb;
    if (a->score != b->score) return a->score > b->score ? -1 : 1;
    int da = (d->entries[a->index].flags & FSE_DIR) != 0, db = (d->entries[b->index].flags & FSE_DIR) != 0;
    if (da != db) return da ? -1 : 1;
    return a->index < b->index ? -1 : 1;
}

uint32_t fse_filter(const fse_dir *d, const char *query, fse_match *out) {
    uint32_t n = 0;
    for (uint32_t i = 0; i < d->count; i++) {
        int32_t s = fse_fuzzy_score(d->arena + d->entries[i].name_off, query);
        if (s < 0) continue;
        out[n].index = i;
        out[n].score = s;
        n++;
    }
    if (n > 1) qsort_r(out, n, sizeof *out, (void *)d, compare_matches);
    return n;
}
