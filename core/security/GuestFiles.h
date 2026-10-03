#pragma once
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dirent.h>
#include <string>
#include <vector>
#include <stdexcept>
#include <cstring>
#include <cerrno>

namespace rctl {
// Descriptor-relative walking protects each component, including the final one,
// against traversal and symlink replacement. The caller supplies a trusted root.
class GuestFiles {
    int root_ = -1;
    static int copyDescriptor(int fd) {
        int copy=fcntl(fd,F_DUPFD_CLOEXEC,0);
        if(copy<0) throw std::runtime_error("directory_unavailable");
        return copy;
    }
public:
    explicit GuestFiles(int root): root_(root) {}
    ~GuestFiles() { if (root_ >= 0) close(root_); }
    GuestFiles(const GuestFiles &) = delete;
    static std::vector<std::string> parts(const std::string &path) {
        if (path.size() > 1024 || (!path.empty() && path.front() == '/')) throw std::runtime_error("invalid_relative_path");
        if (path.empty()) return {};
        std::vector<std::string> parts;
        size_t start = 0;
        while (start < path.size()) {
            auto end = path.find('/', start);
            std::string p = path.substr(start, end == std::string::npos ? end : end - start);
            if (p.empty() || p == "." || p == ".." || p.size() > 240 || p.front() == '.' ||
                p.find('\0') != std::string::npos || p.find('\\') != std::string::npos)
                throw std::runtime_error("invalid_relative_path");
            parts.push_back(p);
            if (end == std::string::npos) break;
            start = end + 1;
            if (start == path.size()) throw std::runtime_error("invalid_relative_path");
        }
        return parts;
    }
    int parent(const std::string &path, std::string &name) const {
        auto p = parts(path);
        if (root_ < 0 || p.empty()) throw std::runtime_error("invalid_relative_path");
        name = p.back(); p.pop_back();
        int dir = copyDescriptor(root_);
        for (const auto &component: p) {
            int next = openat(dir, component.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            close(dir); dir = next;
            if (dir < 0) throw std::runtime_error("directory_unavailable");
        }
        return dir;
    }
    int open(const std::string &path, bool directory = false) const {
        if (path.empty() && directory) { if (root_ < 0) throw std::runtime_error("exchange_unavailable"); return copyDescriptor(root_); }
        std::string name;
        int dir = parent(path, name);
        int fd = openat(dir, name.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (directory ? O_DIRECTORY : 0));
        close(dir);
        struct stat st = {};
        if (fd < 0 || fstat(fd, &st) || !(directory ? S_ISDIR(st.st_mode) : S_ISREG(st.st_mode)) || (!directory && st.st_nlink != 1)) {
            if (fd >= 0) close(fd);
            throw std::runtime_error("file_unavailable");
        }
        return fd;
    }
    void remove(const std::string &path) const {
        std::string name; int dir = parent(path, name);
        struct stat st = {};
        const bool allowed = !fstatat(dir, name.c_str(), &st, AT_SYMLINK_NOFOLLOW) && S_ISREG(st.st_mode) && st.st_nlink == 1;
        int result = allowed ? unlinkat(dir, name.c_str(), 0) : -1;
        close(dir);
        if (result) throw std::runtime_error("delete_failed");
    }
};
}
