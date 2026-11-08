cmake_minimum_required(VERSION 3.16)
project(touchkit LANGUAGES CXX OBJCXX)
# iOS on-screen controls. Use: add_subdirectory(path/to/touchkit ...) and link `touchkit`.
add_library(touchkit STATIC src/touchkit.mm)
target_include_directories(touchkit PUBLIC include)
target_compile_features(touchkit PRIVATE cxx_std_17)
target_compile_options(touchkit PRIVATE -fobjc-arc -Werror=unguarded-availability-new)
target_link_libraries(touchkit PUBLIC "-framework UIKit" "-framework CoreMotion" "-framework GameController"
    "-framework QuartzCore" "-framework Foundation")
