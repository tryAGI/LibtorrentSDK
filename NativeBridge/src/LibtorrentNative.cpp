#include "LibtorrentNative.h"

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/bdecode.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>

#include <atomic>
#include <chrono>
#include <cctype>
#include <cstdint>
#include <iomanip>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {
namespace lt = libtorrent;

struct StartRequest {
    std::string job_id;
    std::string magnet_uri;
    std::string torrent_data_base64;
    std::string download_directory;
    std::optional<long long> download_rate_limit;
    std::optional<long long> upload_rate_limit;
};

struct JobState {
    std::string job_id;
    lt::torrent_handle handle;
    bool completed_sent = false;
};

std::string json_escape(const std::string &value) {
    std::ostringstream output;
    for (const unsigned char character : value) {
        switch (character) {
        case '"':
            output << "\\\"";
            break;
        case '\\':
            output << "\\\\";
            break;
        case '\b':
            output << "\\b";
            break;
        case '\f':
            output << "\\f";
            break;
        case '\n':
            output << "\\n";
            break;
        case '\r':
            output << "\\r";
            break;
        case '\t':
            output << "\\t";
            break;
        default:
            if (character < 0x20) {
                output << "\\u" << std::hex << std::setw(4) << std::setfill('0') << int(character);
            } else {
                output << character;
            }
            break;
        }
    }
    return output.str();
}

std::optional<std::string> extract_json_string(const std::string &json, const std::string &key) {
    const std::string needle = "\"" + key + "\"";
    const auto key_position = json.find(needle);
    if (key_position == std::string::npos) {
        return std::nullopt;
    }

    auto cursor = json.find(':', key_position + needle.size());
    if (cursor == std::string::npos) {
        return std::nullopt;
    }

    ++cursor;
    while (cursor < json.size() && std::isspace(static_cast<unsigned char>(json[cursor]))) {
        ++cursor;
    }

    if (cursor >= json.size() || json[cursor] != '"') {
        return std::nullopt;
    }

    ++cursor;
    std::string value;
    while (cursor < json.size()) {
        const char character = json[cursor++];
        if (character == '"') {
            return value;
        }
        if (character == '\\' && cursor < json.size()) {
            const char escaped = json[cursor++];
            switch (escaped) {
            case '"':
            case '\\':
            case '/':
                value.push_back(escaped);
                break;
            case 'b':
                value.push_back('\b');
                break;
            case 'f':
                value.push_back('\f');
                break;
            case 'n':
                value.push_back('\n');
                break;
            case 'r':
                value.push_back('\r');
                break;
            case 't':
                value.push_back('\t');
                break;
            default:
                value.push_back(escaped);
                break;
            }
        } else {
            value.push_back(character);
        }
    }

    return std::nullopt;
}

std::optional<long long> extract_json_int(const std::string &json, const std::string &key) {
    const std::string needle = "\"" + key + "\"";
    const auto key_position = json.find(needle);
    if (key_position == std::string::npos) {
        return std::nullopt;
    }

    auto cursor = json.find(':', key_position + needle.size());
    if (cursor == std::string::npos) {
        return std::nullopt;
    }

    ++cursor;
    while (cursor < json.size() && std::isspace(static_cast<unsigned char>(json[cursor]))) {
        ++cursor;
    }

    const auto start = cursor;
    if (cursor < json.size() && json[cursor] == '-') {
        ++cursor;
    }
    while (cursor < json.size() && std::isdigit(static_cast<unsigned char>(json[cursor]))) {
        ++cursor;
    }

    if (cursor == start || (cursor == start + 1 && json[start] == '-')) {
        return std::nullopt;
    }

    try {
        return std::stoll(json.substr(start, cursor - start));
    } catch (...) {
        return std::nullopt;
    }
}

std::string percent_decode(std::string value) {
    std::string decoded;
    decoded.reserve(value.size());

    for (std::size_t index = 0; index < value.size(); ++index) {
        if (value[index] == '%' && index + 2 < value.size()) {
            const std::string hex = value.substr(index + 1, 2);
            char *end = nullptr;
            const long code = std::strtol(hex.c_str(), &end, 16);
            if (end != nullptr && *end == '\0') {
                decoded.push_back(static_cast<char>(code));
                index += 2;
                continue;
            }
        }
        decoded.push_back(value[index]);
    }

    return decoded;
}

std::string file_url_to_path(std::string value) {
    constexpr const char *prefix = "file://";
    if (value.rfind(prefix, 0) != 0) {
        return value;
    }

    value.erase(0, std::char_traits<char>::length(prefix));
    if (value.rfind("localhost/", 0) == 0) {
        value.erase(0, std::char_traits<char>::length("localhost"));
    }
    if (!value.empty() && value.front() != '/') {
        value.insert(value.begin(), '/');
    }

    return percent_decode(value);
}

std::vector<std::uint8_t> base64_decode(const std::string &value) {
    static constexpr unsigned char invalid = 255;
    static unsigned char table[256] = {};
    static std::once_flag table_once;
    std::call_once(table_once, [] {
        for (auto &entry : table) {
            entry = invalid;
        }
        const std::string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (std::size_t index = 0; index < alphabet.size(); ++index) {
            table[static_cast<unsigned char>(alphabet[index])] = static_cast<unsigned char>(index);
        }
    });

    std::vector<std::uint8_t> output;
    int accumulator = 0;
    int bits = -8;
    for (const unsigned char character : value) {
        if (std::isspace(character)) {
            continue;
        }
        if (character == '=') {
            break;
        }
        if (table[character] == invalid) {
            continue;
        }
        accumulator = (accumulator << 6) + table[character];
        bits += 6;
        if (bits >= 0) {
            output.push_back(static_cast<std::uint8_t>((accumulator >> bits) & 0xff));
            bits -= 8;
        }
    }
    return output;
}

StartRequest parse_start_request(const char *json) {
    const std::string request_json = json == nullptr ? "" : json;
    StartRequest request;
    request.job_id = extract_json_string(request_json, "jobId").value_or("");
    request.magnet_uri = extract_json_string(request_json, "magnetUri").value_or("");
    request.torrent_data_base64 = extract_json_string(request_json, "torrentData").value_or("");
    request.download_directory = file_url_to_path(
        extract_json_string(request_json, "downloadDirectory").value_or("")
    );
    request.download_rate_limit = extract_json_int(request_json, "downloadBytesPerSecond");
    request.upload_rate_limit = extract_json_int(request_json, "uploadBytesPerSecond");
    return request;
}

std::string parse_job_id(const char *json) {
    const std::string request_json = json == nullptr ? "" : json;
    return extract_json_string(request_json, "jobId").value_or("");
}

lt::settings_pack make_settings() {
    lt::settings_pack settings;
    settings.set_int(
        lt::settings_pack::alert_mask,
        lt::alert_category::error
            | lt::alert_category::storage
            | lt::alert_category::status
    );
    settings.set_bool(lt::settings_pack::enable_dht, true);
    settings.set_bool(lt::settings_pack::enable_lsd, true);
    settings.set_bool(lt::settings_pack::enable_upnp, true);
    settings.set_bool(lt::settings_pack::enable_natpmp, true);
    return settings;
}

int clamp_rate_limit(long long value) {
    if (value <= 0) {
        return 0;
    }
    if (value > std::numeric_limits<int>::max()) {
        return std::numeric_limits<int>::max();
    }
    return static_cast<int>(value);
}

void apply_rate_limits(lt::torrent_handle &handle, const StartRequest &request) {
    if (request.download_rate_limit.has_value()) {
        handle.set_download_limit(clamp_rate_limit(*request.download_rate_limit));
    }
    if (request.upload_rate_limit.has_value()) {
        handle.set_upload_limit(clamp_rate_limit(*request.upload_rate_limit));
    }
}

class NativeSession {
public:
    NativeSession(tryagi_libtorrent_event_callback_t callback, void *context)
        : callback_(callback),
          context_(context),
          session_(make_settings()),
          worker_([this] { pump_progress(); }) {}

    ~NativeSession() {
        stopping_.store(true);
        if (worker_.joinable()) {
            worker_.join();
        }
    }

    int start(const char *json) {
        try {
            auto request = parse_start_request(json);
            if (request.job_id.empty()) {
                return fail("start request is missing jobId");
            }
            if (request.download_directory.empty()) {
                return fail("start request is missing downloadDirectory");
            }

            lt::add_torrent_params params;
            if (!request.magnet_uri.empty()) {
                lt::error_code error;
                params = lt::parse_magnet_uri(request.magnet_uri, error);
                if (error) {
                    return fail("failed to parse magnet URI: " + error.message());
                }
            } else if (!request.torrent_data_base64.empty()) {
                const auto torrent_data = base64_decode(request.torrent_data_base64);
                lt::error_code error;
                lt::bdecode_node decoded;
                lt::bdecode(
                    reinterpret_cast<const char *>(torrent_data.data()),
                    reinterpret_cast<const char *>(torrent_data.data() + torrent_data.size()),
                    decoded,
                    error
                );
                if (error) {
                    return fail("failed to decode torrent data: " + error.message());
                }
                params.ti = std::make_shared<lt::torrent_info>(decoded, error);
                if (error) {
                    return fail("failed to load torrent metadata: " + error.message());
                }
            } else {
                return fail("start request is missing magnetUri or torrentData");
            }

            params.save_path = request.download_directory;
            lt::error_code error;
            auto handle = session_.add_torrent(std::move(params), error);
            if (error) {
                return fail("failed to add torrent: " + error.message());
            }
            apply_rate_limits(handle, request);

            {
                std::lock_guard<std::mutex> guard(lock_);
                jobs_[request.job_id] = JobState{request.job_id, handle, false};
            }
            emit_progress(request.job_id, handle, false);
            return 0;
        } catch (const std::exception &error) {
            return fail(error.what());
        }
    }

    int apply_selection(const char *json) {
        const auto job_id = parse_job_id(json);
        if (job_id.empty()) {
            return fail("selection request is missing jobId");
        }

        std::lock_guard<std::mutex> guard(lock_);
        if (jobs_.find(job_id) == jobs_.end()) {
            return fail("selection request references an unknown jobId");
        }
        return 0;
    }

    int pause(const char *json) {
        return with_handle(json, [](lt::torrent_handle &handle) {
            handle.pause();
        });
    }

    int resume(const char *json) {
        return with_handle(json, [](lt::torrent_handle &handle) {
            handle.resume();
        });
    }

    int cancel(const char *json) {
        const auto job_id = parse_job_id(json);
        if (job_id.empty()) {
            return fail("cancel request is missing jobId");
        }

        lt::torrent_handle handle;
        {
            std::lock_guard<std::mutex> guard(lock_);
            auto iterator = jobs_.find(job_id);
            if (iterator == jobs_.end()) {
                return fail("cancel request references an unknown jobId");
            }
            handle = iterator->second.handle;
            jobs_.erase(iterator);
        }

        if (handle.is_valid()) {
            session_.remove_torrent(handle);
        }
        return 0;
    }

    const char *last_error() const {
        std::lock_guard<std::mutex> guard(lock_);
        return last_error_.empty() ? nullptr : last_error_.c_str();
    }

private:
    template <typename Operation>
    int with_handle(const char *json, Operation operation) {
        const auto job_id = parse_job_id(json);
        if (job_id.empty()) {
            return fail("control request is missing jobId");
        }

        lt::torrent_handle handle;
        {
            std::lock_guard<std::mutex> guard(lock_);
            auto iterator = jobs_.find(job_id);
            if (iterator == jobs_.end()) {
                return fail("control request references an unknown jobId");
            }
            handle = iterator->second.handle;
        }

        if (!handle.is_valid()) {
            return fail("torrent handle is invalid");
        }

        operation(handle);
        return 0;
    }

    int fail(std::string message) {
        std::lock_guard<std::mutex> guard(lock_);
        last_error_ = std::move(message);
        return -1;
    }

    void pump_progress() {
        while (!stopping_.load()) {
            std::this_thread::sleep_for(std::chrono::seconds(1));

            std::vector<std::pair<std::string, lt::torrent_handle>> snapshot;
            {
                std::lock_guard<std::mutex> guard(lock_);
                for (const auto &entry : jobs_) {
                    snapshot.emplace_back(entry.first, entry.second.handle);
                }
            }

            for (const auto &entry : snapshot) {
                emit_progress(entry.first, entry.second, false);
            }
        }
    }

    void emit_progress(const std::string &job_id, const lt::torrent_handle &handle, bool force_completed) {
        if (callback_ == nullptr || !handle.is_valid()) {
            return;
        }

        lt::torrent_status status = handle.status();
        const bool completed = force_completed || status.is_finished;
        const double percent = status.progress_ppm / 10000.0;

        std::ostringstream json;
        json << "{\"type\":\"" << (completed ? "completed" : "progress") << "\",\"progress\":{";
        json << "\"jobId\":\"" << json_escape(job_id) << "\",";
        json << "\"status\":\"" << (completed ? "completed" : "downloading") << "\",";
        json << "\"name\":\"" << json_escape(status.name) << "\",";
        json << "\"bytesCompleted\":" << status.total_done << ",";
        json << "\"totalBytes\":" << status.total_wanted << ",";
        json << "\"percentComplete\":" << percent << ",";
        json << "\"bytesPerSecond\":" << status.download_rate << ",";
        json << "\"peerCount\":" << status.num_peers << ",";
        json << "\"files\":[]";
        json << "}}";

        const auto payload = json.str();
        callback_(payload.c_str(), context_);
    }

    tryagi_libtorrent_event_callback_t callback_;
    void *context_;
    lt::session session_;
    std::atomic_bool stopping_{false};
    mutable std::mutex lock_;
    std::unordered_map<std::string, JobState> jobs_;
    std::string last_error_;
    std::thread worker_;
};

NativeSession *as_session(void *session) {
    return reinterpret_cast<NativeSession *>(session);
}
} // namespace

int tryagi_libtorrent_session_create(
    tryagi_libtorrent_event_callback_t callback,
    void *context,
    void **session
) {
    if (session == nullptr) {
        return -1;
    }

    try {
        *session = new NativeSession(callback, context);
        return 0;
    } catch (...) {
        *session = nullptr;
        return -1;
    }
}

void tryagi_libtorrent_session_destroy(void *session) {
    delete as_session(session);
}

int tryagi_libtorrent_job_start(void *session, const char *json) {
    auto *native_session = as_session(session);
    return native_session == nullptr ? -1 : native_session->start(json);
}

int tryagi_libtorrent_job_apply_selection(void *session, const char *json) {
    auto *native_session = as_session(session);
    return native_session == nullptr ? -1 : native_session->apply_selection(json);
}

int tryagi_libtorrent_job_pause(void *session, const char *json) {
    auto *native_session = as_session(session);
    return native_session == nullptr ? -1 : native_session->pause(json);
}

int tryagi_libtorrent_job_resume(void *session, const char *json) {
    auto *native_session = as_session(session);
    return native_session == nullptr ? -1 : native_session->resume(json);
}

int tryagi_libtorrent_job_cancel(void *session, const char *json) {
    auto *native_session = as_session(session);
    return native_session == nullptr ? -1 : native_session->cancel(json);
}

const char *tryagi_libtorrent_last_error(void *session) {
    auto *native_session = as_session(session);
    return native_session == nullptr ? nullptr : native_session->last_error();
}
