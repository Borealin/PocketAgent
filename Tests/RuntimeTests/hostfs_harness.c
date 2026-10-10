// Host-side exercise of the patched iSH hostfs backend (fs/hostfs/hostfs_user.c).
// Built and run by test_hostfs.py on macOS; prints one JSON object.
//
//   functional: ordinary operations below the mount root succeed and
//               symbolic links, "..", foreign roots and an unset root are refused.
//   controls:   the operation sequence below, without a race, succeeds exactly
//               (parent in place) and is refused with ELOOP everywhere (parent
//               replaced by a link to the outside directory).
//   race:       another thread repeatedly replaces the parent directory with a
//               symbolic link to a sibling outside the root while reads,
//               creates, truncates, unlinks, renames and mkdirs run through it.
//               It runs at least `iterations` times and until successful
//               reads, successful writes and ELOOP refusals were all observed.
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "hostfs.h"

int pocket_hostfs_set_root(const char *root);

static char base[PATH_MAX], root[PATH_MAX], outside[PATH_MAX], parent[PATH_MAX], parked[PATH_MAX];
static atomic_int stop;
static int failures;

#define CHECK(condition) do { if (!(condition)) { failures++; fprintf(stderr, "check failed line %d: %s\n", __LINE__, #condition); } } while (0)

static void path(char *out, const char *relative) { snprintf(out, PATH_MAX, "/%s/%s", root, relative); }

static void write_text(const char *file, const char *text) {
    FILE *f = fopen(file, "w");
    fputs(text, f);
    fclose(f);
}

static int outside_entries(void) {
    DIR *dir = opendir(outside);
    int count = 0;
    for (struct dirent *e; (e = readdir(dir));) if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) count++;
    closedir(dir);
    return count;
}

static void functional(void) {
    char p[PATH_MAX], q[PATH_MAX], buffer[64];
    struct hostfs_stat st;
    unsigned long long offset = 0;

    path(p, "dir");
    CHECK(do_mkdir(p, 0755) == 0);
    path(p, "dir/a.txt");
    int fd = file_create(p, 0644);
    CHECK(fd >= 0);
    CHECK(write_file(fd, &offset, "hello", 5) == 5);
    close(fd);
    CHECK(stat_file(p, &st, -1) == 0 && st.size == 5);
    CHECK(access_file(p, 1, 1, 0) == 0);
    struct hostfs_iattr attrs = { .ia_valid = HOSTFS_ATTR_SIZE | HOSTFS_ATTR_MODE | HOSTFS_ATTR_MTIME_SET,
                                  .ia_size = 2, .ia_mode = 0600, .ia_mtime = { 1000000, 0 } };
    CHECK(set_attr(p, &attrs, -1) == 0);
    CHECK(stat_file(p, &st, -1) == 0 && st.size == 2 && (st.mode & 0777) == 0600 && st.mtime.tv_sec == 1000000);
    fd = open_file(p, 1, 0, 0);
    offset = 0;
    CHECK(fd >= 0 && read_file(fd, &offset, buffer, sizeof buffer) == 2);
    if (fd >= 0) close(fd);
    path(q, "dir/b.txt");
    CHECK(rename_file(p, q) == 0);
    CHECK(rename2_file(q, p, 1) == 0);           // RENAME_NOREPLACE
    path(q, "dir/hard.txt");
    CHECK(link_file(p, q) == 0);
    CHECK(unlink_file(q) == 0);
    path(q, "dir/link");
    CHECK(make_symlink(q, "/etc/hosts") == 0);
    CHECK(hostfs_do_readlink(q, buffer, sizeof buffer) == 10 && strcmp(buffer, "/etc/hosts") == 0);
    CHECK(stat_file(q, &st, -1) == 0 && S_ISLNK(st.mode));
    CHECK(open_file(q, 1, 0, 0) == -ELOOP);       // a link is never followed
    CHECK(unlink_file(q) == 0);
    int error = 0;
    path(q, "");
    void *dir = open_dir(q, &error);              // the mount root itself
    CHECK(dir != NULL);
    if (dir) close_dir(dir);
    long bsize, namelen; long long blocks, bfree, bavail, files, ffree; char fsid[8];
    CHECK(do_statfs(q, &bsize, &blocks, &bfree, &bavail, &files, &ffree, fsid, sizeof fsid, &namelen) == 0);
    CHECK(unlink_file(p) == 0);
    path(p, "dir");
    CHECK(hostfs_do_rmdir(p) == 0);

    snprintf(p, PATH_MAX, "%s/file", outside);
    CHECK(open_file(p, 1, 0, 0) == -EACCES);      // outside the root
    path(p, "../outside/file");
    CHECK(open_file(p, 1, 0, 0) == -EACCES);      // no ".." below the root
    snprintf(p, PATH_MAX, "%s-sibling/file", root);
    CHECK(open_file(p, 1, 0, 0) == -EACCES);      // prefix of a component is not the root
    char longer[2 * PATH_MAX];
    snprintf(longer, sizeof longer, "/%s/%01100d", root, 0);
    CHECK(open_file(longer, 1, 0, 0) == -ENAMETOOLONG);   // longer than the host can open
    CHECK(pocket_hostfs_set_root(NULL) == 0);
    path(p, "parent/file");
    CHECK(open_file(p, 1, 0, 0) == -EACCES);      // no root: everything refused
    CHECK(pocket_hostfs_set_root(root) == 0);
}

struct counts { int reads, writes, outsideReads, looped; };

static void count(struct counts *c, int result, int success) {
    if (result == success) c->writes++;
    else if (result == -ELOOP) c->looped++;
}

// One pass of the operation sequence through parent/. Fully successful, it is
// one read and seven writes (the second unlink of "new" finds it renamed).
static void iteration(struct counts *c) {
    char p[PATH_MAX], q[PATH_MAX], data[32];
    path(p, "parent/file");
    int fd = open_file(p, 1, 0, 0);
    if (fd >= 0) {
        unsigned long long offset = 0;
        memset(data, 0, sizeof data);
        read_file(fd, &offset, data, sizeof data - 1);
        close(fd);
        c->reads++;
        if (strstr(data, "OUTSIDE")) c->outsideReads++;
    } else if (fd == -ELOOP) {
        c->looped++;
    }
    struct hostfs_iattr attrs = { .ia_valid = HOSTFS_ATTR_SIZE | HOSTFS_ATTR_MODE, .ia_size = 0, .ia_mode = 0600 };
    count(c, set_attr(p, &attrs, -1), 0);
    path(p, "parent/new");
    fd = file_create(p, 0644);
    if (fd >= 0) close(fd);
    count(c, fd >= 0 ? 0 : fd, 0);
    path(q, "parent/renamed");
    count(c, rename_file(p, q), 0);
    count(c, unlink_file(q), 0);
    count(c, unlink_file(p), 0);
    path(p, "parent/sub");
    count(c, do_mkdir(p, 0755), 0);
    count(c, hostfs_do_rmdir(p), 0);
    path(p, "parent/file");
    count(c, unlink_file(p), 0);
    int restore = file_create(p, 0644);
    if (restore >= 0) {
        unsigned long long offset = 0;
        write_file(restore, &offset, "inside", 6);
        close(restore);
    }
}

static void *swap_parent(void *unused) {
    (void)unused;
    while (!atomic_load(&stop)) {
        if (rename(parent, parked) == 0) {
            symlink(outside, parent);
            usleep(5);
            unlink(parent);
            rename(parked, parent);
        }
    }
    return NULL;
}

int main(int argc, char **argv) {
    int iterations = argc > 1 ? atoi(argv[1]) : 20000;
    char template[] = "/tmp/pocketagent-hostfs-XXXXXX";
    // /tmp is a symbolic link on macOS (like /var on iOS): the root is canonical.
    if (!realpath(mkdtemp(template), base)) return 2;
    snprintf(root, PATH_MAX, "%s/project", base);
    snprintf(outside, PATH_MAX, "%s/outside", base);
    snprintf(parent, PATH_MAX, "%s/parent", root);
    snprintf(parked, PATH_MAX, "%s/parked", root);
    mkdir(root, 0755); mkdir(outside, 0755); mkdir(parent, 0755);
    char sentinel[PATH_MAX], file[PATH_MAX];
    snprintf(sentinel, PATH_MAX, "%s/file", outside);
    write_text(sentinel, "OUTSIDE_SENTINEL");
    chmod(sentinel, 0644);
    snprintf(file, PATH_MAX, "%s/file", parent);
    write_text(file, "inside");

    char noncanonical[PATH_MAX];
    snprintf(noncanonical, PATH_MAX, "%s/project", template);
    CHECK(pocket_hostfs_set_root(noncanonical) == 0);
    char probe[PATH_MAX];
    snprintf(probe, PATH_MAX, "/%s/parent/file", noncanonical);
    CHECK(open_file(probe, 1, 0, 0) == -ELOOP);   // a root through /tmp is refused
    CHECK(pocket_hostfs_set_root(root) == 0);
    functional();

    // Controls: no concurrent swap, so every outcome is deterministic.
    enum { CONTROL = 50 };
    struct counts control = {0}, linked = {0}, race = {0};
    for (int i = 0; i < CONTROL; i++) iteration(&control);
    CHECK(control.reads == CONTROL && control.writes == 7 * CONTROL && control.looped == 0);
    CHECK(rename(parent, parked) == 0 && symlink(outside, parent) == 0);
    for (int i = 0; i < CONTROL; i++) iteration(&linked);
    CHECK(unlink(parent) == 0 && rename(parked, parent) == 0);
    // Linked: the read and all eight write attempts hit the link.
    CHECK(linked.reads == 0 && linked.writes == 0 && linked.looped == 9 * CONTROL);

    pthread_t thread;
    pthread_create(&thread, NULL, swap_parent, NULL);
    int i = 0;
    for (; i < 10 * iterations && !race.outsideReads; i++) {
        if (i >= iterations && race.reads && race.writes && race.looped) break;
        iteration(&race);
    }
    atomic_store(&stop, 1);
    pthread_join(thread, NULL);
    // The race really went through the parent both ways.
    CHECK(race.reads > 0 && race.writes > 0 && race.looped > 0);

    struct stat info = {0};
    char contents[32] = {0};
    FILE *f = fopen(sentinel, "r");
    if (f) {
        fread(contents, 1, sizeof contents - 1, f);
        fclose(f);
    }
    int outsideChanged = !f || stat(sentinel, &info) != 0 || strcmp(contents, "OUTSIDE_SENTINEL") != 0 ||
                         (info.st_mode & 0777) != 0644 || outside_entries() != 1;
    printf("{\"failures\": %d, \"iterations\": %d, \"reads\": %d, \"writes\": %d, \"looped\": %d, "
           "\"outsideReads\": %d, \"outsideChanged\": %d, \"control\": [%d, %d, %d], \"linked\": [%d, %d, %d]}\n",
           failures, i, race.reads, race.writes, race.looped, control.outsideReads + linked.outsideReads + race.outsideReads,
           outsideChanged, control.reads, control.writes, control.looped, linked.reads, linked.writes, linked.looped);
    char command[PATH_MAX + 16];
    snprintf(command, sizeof command, "rm -rf '%s'", base);
    system(command);
    return 0;
}
