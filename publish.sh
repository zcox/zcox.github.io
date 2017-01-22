#!/bin/bash

bundle exec jekyll build && s3_website push
