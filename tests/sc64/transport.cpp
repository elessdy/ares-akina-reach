#include "../../ares/n64/sc64/host-socket.hpp"
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <thread>

using ares::Nintendo64::SC64HostSocket;
#if defined(_WIN32)
using Handle = SOCKET;
constexpr auto Invalid = INVALID_SOCKET;
#else
using Handle = int;
constexpr auto Invalid = -1;
#endif

static auto require(bool condition, const char* message) -> void {
  if(!condition) throw std::runtime_error(message);
}

struct Peer {
  Handle socket = Invalid;
  ~Peer() { close(); }
  auto close() -> void {
    if(socket == Invalid) return;
#if defined(_WIN32)
    closesocket(socket);
#else
    ::close(socket);
#endif
    socket = Invalid;
  }
  auto nonblocking() -> void {
#if defined(_WIN32)
    u_long enabled = 1;
    require(ioctlsocket(socket, FIONBIO, &enabled) == 0, "peer nonblocking");
#else
    require(fcntl(socket, F_SETFL, fcntl(socket, F_GETFL, 0) | O_NONBLOCK) == 0, "peer nonblocking");
#endif
  }
};

static auto vacantPort() -> uint16_t {
  Peer peer;
  peer.socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  require(::bind(peer.socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0, "allocate port");
#if defined(_WIN32)
  int size = sizeof(address);
#else
  socklen_t size = sizeof(address);
#endif
  require(getsockname(peer.socket, reinterpret_cast<sockaddr*>(&address), &size) == 0, "get port");
  return ntohs(address.sin_port);
}

static auto connect(Peer& peer, uint16_t port) -> void {
  peer.socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  require(peer.socket != Invalid, "create peer");
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = htons(port);
  require(::connect(peer.socket, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0, "connect peer");
}

static auto poll(SC64HostSocket& server) -> void {
  server.poll([] {}, [](const std::vector<uint8_t>&) {});
}

static auto runTests() -> void {
  SC64HostSocket server;
  auto port = vacantPort();
  require(server.open(port), "open loopback listener");
  SC64HostSocket conflict;
  require(!conflict.open(port) && !conflict.isStarted(), "occupied port must fail synchronously");
  Peer peer;
  connect(peer, port);
  unsigned connections = 0;
  server.poll([&] { ++connections; }, [](const auto&) {});
  require(connections == 1 && server.hasClient(), "accept callback once");

  // A single poll must not drain unbounded output. Continue polling with a
  // deliberately slow peer and compare every byte through partial writes.
  std::vector<uint8_t> frame(1024 * 1024);
  for(size_t i = 0; i < frame.size(); ++i) frame[i] = static_cast<uint8_t>(i * 73 + i / 256);
  require(server.send(frame), "queue complete frame");
  poll(server);
  peer.nonblocking();
  std::vector<uint8_t> received;
  std::array<uint8_t, 8192> scratch{};
  auto drain = [&] {
    while(true) {
      auto count = ::recv(peer.socket, reinterpret_cast<char*>(scratch.data()), static_cast<int>(scratch.size()), 0);
      if(count <= 0) break;
      received.insert(received.end(), scratch.begin(), scratch.begin() + count);
    }
  };
  drain();
  require(received.size() <= SC64HostSocket::PollByteBudget, "send budget");
  auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
  while(received.size() < frame.size() && std::chrono::steady_clock::now() < deadline) {
    poll(server);
    drain();
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  require(received == frame, "partial sends preserve full frame byte-for-byte");

  // Fill the receiving kernel buffer, then prove a poll has a byte budget.
  auto sent = ::send(peer.socket, reinterpret_cast<const char*>(frame.data()), static_cast<int>(frame.size()), 0);
  require(sent > 0, "send incoming traffic");
  size_t inputBytes = 0;
  server.poll([] {}, [&](const auto& data) { inputBytes += data.size(); });
  require(inputBytes > 0 && inputBytes <= SC64HostSocket::PollByteBudget, "receive budget");

  // Command dispatch reserves the largest supported response before consuming
  // input. An existing async frame must reduce the available frame slots;
  // pending commands resume once polling drains that output.
  require(server.send({0x55}), "queue asynchronous output before commands");
  size_t admitted = 0;
  while(server.canQueue(16 * 1024 * 1024 + 10)) {
    require(server.send({0x76}), "queue admitted command response");
    ++admitted;
  }
  require(admitted == SC64HostSocket::MaxQueuedFrames - 1, "command frame capacity reserves async output");
  require(server.hasClient(), "backpressure must not disconnect client");
  poll(server);
  require(server.canQueue(16 * 1024 * 1024 + 10), "pending command resumes after output drains");
  std::vector<uint8_t> pendingMemory(64 * 1024, 0x6d);
  require(server.send(pendingMemory), "queue pending memory response");
  require(!server.canQueue(16 * 1024 * 1024 + 10), "command byte capacity applies backpressure");
  poll(server);
  require(server.canQueue(16 * 1024 * 1024 + 10), "byte capacity recovers after output drains");

  // A slow consumer may fill either bound; overflow closes the whole stream.
  for(size_t i = 0; i < SC64HostSocket::MaxQueuedFrames; ++i)
    require(server.send({1, 2, 3}), "queue allowed frame count");
  require(!server.send({4}) && !server.hasClient(), "frame count bound disconnects");
  peer.close();
  connect(peer, port);
  server.poll([&] { ++connections; }, [](const auto&) {});
  require(connections == 2 && server.hasClient(), "reconnect after overflow");
  std::vector<uint8_t> large(SC64HostSocket::MaxQueuedBytes, 0x5a);
  require(server.send(large), "queue allowed byte count");
  require(!server.send({1}) && !server.hasClient(), "byte bound disconnects without wrapping");
  peer.close();

  // No callbacks/workers may outlive close, including immediate open/close
  // before any connection. Connections use fresh ports to avoid TIME_WAIT.
  for(unsigned i = 0; i < 100; ++i) {
    server.close();
    require(server.open(vacantPort()), "immediate close/reopen");
  }
  server.close();
  port = vacantPort();
  require(server.open(port), "open after repeated close");
  connect(peer, port);
  server.poll([&] { ++connections; }, [](const auto&) {});
  require(connections == 3, "fresh callback after reopen");
  peer.close();
  deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while(server.hasClient() && std::chrono::steady_clock::now() < deadline) poll(server);
  require(!server.hasClient(), "orderly peer close observed");
  connect(peer, port);
  server.poll([&] { ++connections; }, [](const auto&) {});
  require(connections == 4, "rapid disconnect/reconnect has distinct accept callback");
  peer.nonblocking();
  auto stale = ::recv(peer.socket, reinterpret_cast<char*>(scratch.data()), static_cast<int>(scratch.size()), 0);
  require(stale < 0, "reconnection does not receive stale queued output");
  server.close();
  server.close();
  require(!server.hasClient() && !server.isStarted(), "close is idempotent");
}

int main() {
#if defined(_WIN32)
  WSADATA data{};
  if(WSAStartup(MAKEWORD(2, 2), &data) != 0) return 1;
#endif
  int result = 0;
  try { runTests(); std::cout << "SC64 socket regressions passed\n"; }
  catch(const std::exception& error) { std::cerr << error.what() << '\n'; result = 1; }
#if defined(_WIN32)
  WSACleanup();
#endif
  return result;
}
