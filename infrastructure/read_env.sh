#!/bin/bash
# Convert .env to a JSON object for Terraform
jq -Rs 'split("\n") | map(select(length > 0 and (startswith("#") | not))) | map(split("=")) | map({(.[0]): .[1]}) | add' .env
