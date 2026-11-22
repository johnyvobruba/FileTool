// Deklarace z libarchive (součást macOS: /usr/lib/libarchive.2.dylib), jen to, co FileTool používá.
// SDK macOS hlavičky libarchive neobsahuje, proto vlastní prototypy (stabilní C API libarchive 3.x).
#ifndef CARCHIVE_H
#define CARCHIVE_H
#include <stdint.h>
#include <sys/types.h>
#include <time.h>

struct archive;
struct archive_entry;

#define CA_OK 0
#define CA_EOF 1
#define CA_RETRY (-10)
#define CA_WARN (-20)
#define CA_FAILED (-25)
#define CA_FATAL (-30)

struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *, size_t);
int archive_read_data_skip(struct archive *);
int archive_read_free(struct archive *);
const char *archive_error_string(struct archive *);
int archive_format(struct archive *);
const char *archive_format_name(struct archive *);

const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
mode_t archive_entry_perm(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);

#endif
