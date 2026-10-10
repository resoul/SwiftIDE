#include "cxxlib.hpp"

namespace cxxlib {

Greeter::Greeter(std::string name) : name_(std::move(name)) {}

std::string Greeter::greeting() const {
    return "Hello, " + name_ + "!";
}

std::vector<std::string> Greeter::greetings(int times) const {
    return std::vector<std::string>(static_cast<size_t>(times), greeting());
}

}  // namespace cxxlib
