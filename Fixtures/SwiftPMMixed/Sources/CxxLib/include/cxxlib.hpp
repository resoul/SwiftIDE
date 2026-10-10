#pragma once

#include <string>
#include <vector>

namespace cxxlib {

class Greeter {
public:
    explicit Greeter(std::string name);
    std::string greeting() const;
    std::vector<std::string> greetings(int times) const;

private:
    std::string name_;
};

}  // namespace cxxlib
