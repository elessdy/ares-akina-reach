#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <vector>

#if defined(_WIN32)
  #ifndef WIN32_LEAN_AND_MEAN
    #define WIN32_LEAN_AND_MEAN
  #endif
  #ifndef NOMINMAX
    #define NOMINMAX
  #endif
  #include <winsock2.h>
  #include <ws2tcpip.h>
#else
  #include <cerrno>
  #include <fcntl.h>
  #include <netinet/in.h>
  #include <netinet/tcp.h>
  #include <sys/socket.h>
  #include <unistd.h>
#endif

namespace ares::Nintendo64 {

// SC64 only. All methods run on the emulation thread. No detached workers,
// cross-thread callbacks, or socket handles that can outlive their owner.
class SC64HostSocket {
public:
  static constexpr size_t MaxQueuedBytes = 16 * 1024 * 1024 + 32 * 1024;
  static constexpr size_t MaxQueuedFrames = 64;
  static constexpr size_t PollByteBudget = 64 * 1024;

  SC64HostSocket() = default;
  SC64HostSocket(const SC64HostSocket&) = delete;
  auto operator=(const SC64HostSocket&) -> SC64HostSocket& = delete;
  ~SC64HostSocket() { close(); }

  auto open(uint16_t port) -> bool {
    close();
    listener = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if(listener == Invalid) return false;
    int enabled = 1;
#if defined(_WIN32)
    // Do not allow another listener to hijack this port on Windows.
    ::setsockopt(listener, SOL_SOCKET, SO_EXCLUSIVEADDRUSE,
      reinterpret_cast<const char*>(&enabled), sizeof(enabled));
#else
    ::setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));
#endif
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(port);
    if(!nonblocking(listener)
    || ::bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0
    || ::listen(listener, 1) != 0) {
      close();
      return false;
    }
    return true;
  }

  auto close() -> void {
    disconnectClient();
    closeSocket(listener);
    listener = Invalid;
  }

  auto disconnectClient() -> void {
    closeSocket(client);
    client = Invalid;
    output.clear();
    outputBytes = 0;
    outputOffset = 0;
  }

  auto hasClient() const -> bool { return client != Invalid; }
  auto isStarted() const -> bool { return listener != Invalid; }

  auto canQueue(size_t bytes) const -> bool {
    return hasClient() && bytes <= MaxQueuedBytes - outputBytes && output.size() < MaxQueuedFrames;
  }

  // Queue a complete frame, or terminate the stream. Never drop arbitrary
  // bytes from a frame, silently overwrite queued data, or grow without bound.
  auto send(const std::vector<uint8_t>& frame) -> bool {
    if(!hasClient()) return false;
    if(!canQueue(frame.size())) {
      disconnectClient();
      return false;
    }
    if(frame.empty()) return true;
    output.push_back(frame);
    outputBytes += frame.size();
    return true;
  }

  template<typename Connected, typename Received>
  auto poll(Connected connected, Received received) -> void {
    if(!isStarted()) return;
    if(!hasClient()) {
      client = ::accept(listener, nullptr, nullptr);
      if(!hasClient()) return;
      if(!nonblocking(client)) { disconnectClient(); return; }
      int enabled = 1;
      ::setsockopt(client, IPPROTO_TCP, TCP_NODELAY,
        reinterpret_cast<const char*>(&enabled), sizeof(enabled));
#if defined(SO_NOSIGPIPE)
      ::setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#endif
      // Reset framing and USB state before any bytes from this connection.
      connected();
    }

    std::array<uint8_t, 16 * 1024> buffer;
    size_t budget = PollByteBudget;
    while(hasClient() && budget) {
      auto count = ::recv(client, reinterpret_cast<char*>(buffer.data()),
        static_cast<int>(std::min(buffer.size(), budget)), 0);
      if(count > 0) {
        budget -= count;
        received(std::vector<uint8_t>(buffer.begin(), buffer.begin() + count));
      } else {
        if(count == 0 || !wouldBlock()) disconnectClient();
        break;
      }
    }

    budget = PollByteBudget;
    while(hasClient() && !output.empty() && budget) {
      auto& frame = output.front();
      auto length = std::min(frame.size() - outputOffset, budget);
#if defined(MSG_NOSIGNAL)
      constexpr int flags = MSG_NOSIGNAL;
#else
      constexpr int flags = 0;
#endif
      auto count = ::send(client, reinterpret_cast<const char*>(frame.data() + outputOffset),
        static_cast<int>(length), flags);
      if(count > 0) {
        outputOffset += count;
        budget -= count;
        if(outputOffset == frame.size()) {
          outputBytes -= frame.size();
          output.pop_front();
          outputOffset = 0;
        }
      } else {
        if(count == 0 || !wouldBlock()) disconnectClient();
        break;
      }
    }
  }

private:
#if defined(_WIN32)
  using Handle = SOCKET;
  static constexpr Handle Invalid = INVALID_SOCKET;
#else
  using Handle = int;
  static constexpr Handle Invalid = -1;
#endif
  Handle listener = Invalid;
  Handle client = Invalid;
  std::deque<std::vector<uint8_t>> output;
  size_t outputBytes = 0;
  size_t outputOffset = 0;

  static auto nonblocking(Handle socket) -> bool {
#if defined(_WIN32)
    u_long enabled = 1;
    return ioctlsocket(socket, FIONBIO, &enabled) == 0;
#else
    auto flags = fcntl(socket, F_GETFL, 0);
    return flags >= 0 && fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0;
#endif
  }

  static auto wouldBlock() -> bool {
#if defined(_WIN32)
    auto error = WSAGetLastError();
    return error == WSAEWOULDBLOCK || error == WSAEINTR;
#else
    return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
#endif
  }

  static auto closeSocket(Handle socket) -> void {
    if(socket == Invalid) return;
#if defined(_WIN32)
    ::closesocket(socket);
#else
    ::close(socket);
#endif
  }
};

}
