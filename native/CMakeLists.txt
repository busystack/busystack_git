cmake_minimum_required(VERSION 3.24)
project(busystack_git_helper C)
add_executable(busystack-git-helper git_helper.c)
target_compile_features(busystack-git-helper PRIVATE c_std_11)
target_compile_options(busystack-git-helper PRIVATE -Wall -Wextra -Werror)
if(NOT DEFINED BUSYSTACK_GIT_HELPER_INSTALL_DIR)
  set(BUSYSTACK_GIT_HELPER_INSTALL_DIR libexec/busystack)
endif()
install(TARGETS busystack-git-helper RUNTIME DESTINATION ${BUSYSTACK_GIT_HELPER_INSTALL_DIR} COMPONENT Runtime)

# Both consumers build the same verified upstream source. No network, SDK, or
# developer cache is needed at application runtime or during source extraction.
include(ExternalProject)
find_program(BUSYSTACK_GIT_MAKE NAMES gmake make REQUIRED)
set(BUSYSTACK_GIT_RUNTIME_ROOT "${CMAKE_CURRENT_BINARY_DIR}/git-runtime")
ExternalProject_Add(busystack-git-runtime
  URL "${CMAKE_CURRENT_SOURCE_DIR}/vendor/git-2.56.0.tar.xz"
  URL_HASH SHA256=26c56c296b38c0695b26fa95f475f1d01704d2d38e73465ca30b0b2f5dc789d3
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
  UPDATE_COMMAND ""
  CONFIGURE_COMMAND ""
  BUILD_IN_SOURCE TRUE
  BUILD_COMMAND "${BUSYSTACK_GIT_MAKE}" -j4
    "prefix=${BUSYSTACK_GIT_RUNTIME_ROOT}" RUNTIME_PREFIX=YesPlease NO_RUST=YesPlease NO_TCLTK=YesPlease
    NO_GETTEXT=YesPlease NO_PERL=YesPlease INSTALL_SYMLINKS=YesPlease
    COMMAND "${BUSYSTACK_GIT_MAKE}" -C <SOURCE_DIR>/contrib/credential/libsecret
      "prefix=${BUSYSTACK_GIT_RUNTIME_ROOT}"
  INSTALL_COMMAND "${BUSYSTACK_GIT_MAKE}" "prefix=${BUSYSTACK_GIT_RUNTIME_ROOT}"
    RUNTIME_PREFIX=YesPlease NO_RUST=YesPlease NO_TCLTK=YesPlease NO_GETTEXT=YesPlease NO_PERL=YesPlease INSTALL_SYMLINKS=YesPlease install
    COMMAND "${BUSYSTACK_GIT_MAKE}" -C <SOURCE_DIR>/contrib/credential/libsecret
      "prefix=${BUSYSTACK_GIT_RUNTIME_ROOT}" install
  BUILD_BYPRODUCTS "${BUSYSTACK_GIT_RUNTIME_ROOT}/bin/git")
install(DIRECTORY "${BUSYSTACK_GIT_RUNTIME_ROOT}/" DESTINATION libexec/git-runtime
  USE_SOURCE_PERMISSIONS COMPONENT Runtime)
install(FILES vendor/GIT-COPYING DESTINATION libexec/git-runtime/share/licenses COMPONENT Runtime)
