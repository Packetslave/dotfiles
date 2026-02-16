This is a directory for one-off scripts and tools.

# Shell Scripts

Important Rules:
  * if creating or editing a shell script, prefer bash 
  * always start a new shell script with the [minimal safe Bash template](https://betterdev.blog/minimal-safe-bash-script-template/)
  * always run shellcheck after making changes to any shell script. Must pass without errors or warnings

# Python Scripts

If you're writing a Python script, it should be a single file and start with this comment:

# /// script
# requires-python = ">=3.12"
# ///

These files can include dependencies on libraries such as Click. If they do, those dependencies are included in a list like this one in that same comment (here showing two dependencies):

# /// script
# requires-python = ">=3.12"
# dependencies = [
#     "click",
#     "sqlite-utils",
# ]
# ///

You can run these Python scripts with `uv run script_name.py`
