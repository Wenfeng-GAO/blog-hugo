#!/bin/bash

echo -e "\033[0;32mDeploying updates to GitHub...\033[0m"

# Build the project.
hugo -t even

# Go To Public folder
cd public
# Add changes to git.
git add .

# Commit changes.
msg="rebuilding site `date`"
if [ $# -eq 1 ]
  then msg="$1"
fi
git commit -m "$msg"

# 5. Return to the project root.
cd ../

git add .
git commit -m "update submodule reference"

# 8. Push the source project *and* the public submodule to Github together.
git push -u origin master --recurse-submodules=on-demand

# # Push source and build repos.
# git push origin master
#
# # Come Back up to the Project Root
# cd ..
