#!/bin/bash
###################################################
# Small bash library for simplifying the use of flags in bash scrips
###################################################
# Usage (in the script):
#   source "flags.sh"
#
#   FLAG var_a
#   FLAG var_b "default value"
#   PARSE_ALL_FLAGS $0 "${@}"  # Pass binary name and flags to the library
#
#   echo "Now I can refer to the flags, which were: ${var_a} and ${var_b}"
###################################################
# Usage (on the command line):
#   $ ./my_script --var_a="blah blah" # don't set var_b to use its default value
#   Now I can refer to the flags which were blah blah and default value
###################################################
# TODO:
#   -Binary flags (--use_flux_capacitor and --nouse_flux_capacitor)
#   -Get rid of python command below

__FLAGS__=()
__FILL_DEFAULTS__=()

function FLAG {
  __FLAGS__+=("$1:")  # Two colons means "followed by an optional argument"
  __FILL_DEFAULTS__+=("$1=\"$2\"")
}

function PARSE_ALL_FLAGS {
  # Fill default values
  for cmd in "${__FILL_DEFAULTS__[@]}"; do
    eval "${cmd}"
  done

  # First element of sys.argv is "-c" so omit that by joining argv[1:] instead
  local flags="$( python -c 'import sys; print ",".join(sys.argv[1:])' "${__FLAGS__[@]}" )"
  local OPTS=( $(getopt -n "$1" -l "${flags}" -- ${@:1}) )

  # Read all args to PARSE_ALL_FLAGS and use them to set the flag values
  while [[ "${#OPTS[@]}" -gt 1 ]] && [[ "${OPTS[0]}" != '--' ]]; do
    # :2 removes the "--" from the front of the long arg's name
    # Note that even though the arguments were optional, getopt will place an empty
    # string in ${OPTS[1]} if the flag is set without an argument (--var_a vs. --var_a=XYZ),
    # so this command still works in that case (it assigns the empty string)
    eval ${OPTS[0]:2}=${OPTS[1]}
    OPTS=( "${OPTS[@]:2}" )
  done

  # return leftover args
  echo "${OPTS[@]:1}"
}