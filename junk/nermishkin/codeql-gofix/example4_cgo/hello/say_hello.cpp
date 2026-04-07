#include "say_hello.h"

#include <cstring>
#include <string>

char* SayHello(const char* name) {
    std::string greeting = "Hello, ";
    greeting += name;
    greeting += "!";

    char* result = new char[greeting.size() + 1];
    std::memcpy(result, greeting.c_str(), greeting.size() + 1);
    return result;
}
