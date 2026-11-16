#!/bin/bash
# Download counts per release file, as counted by GitHub. Needs the gh CLI.
gh api repos/elpresidentex/brain-input/releases --jq '.[] | .tag_name as $t | .assets[] | "\($t)  \(.name)  \(.download_count) downloads"'
