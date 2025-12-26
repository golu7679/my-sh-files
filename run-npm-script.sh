#!/bin/sh

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ---- Check package.json ----
if [ ! -f package.json ]; then
  printf "${RED}✖ package.json not found${RESET}\n"
  exit 1
fi

# ---- Extract scripts using Node.js ----
SCRIPTS=$(node -e '
const scripts = require("./package.json").scripts || {};
Object.entries(scripts).forEach(([name, value], i) => {
  console.log((i + 1) + "|" + name + "|" + value);
});
')

# ---- No scripts ----
if [ -z "$SCRIPTS" ]; then
  printf "${YELLOW}! No scripts found in package.json${RESET}\n"
  exit 0
fi

# ---- Header ----
printf "\n${BOLD}${CYAN}Available npm scripts${RESET}\n"
printf "${BLUE}--------------------------------------------------${RESET}\n"

# ---- Print scripts ----
echo "$SCRIPTS" | while IFS='|' read index name value; do
  printf "${GREEN}%s${RESET}) ${BOLD}%s${RESET} ${YELLOW}->${RESET} %s\n" \
    "$index" "$name" "$value"
done

printf "${BLUE}--------------------------------------------------${RESET}\n"
printf "${CYAN}Enter script number to run or press Q to quit:${RESET} "

# ---- Read input ----
read INPUT

# ---- Quit option ----
case "$INPUT" in
  q|Q)
    printf "\n${YELLOW}Exiting...${RESET}\n"
    exit 0
    ;;
esac

# ---- Resolve script name ----
SCRIPT_NAME=$(echo "$SCRIPTS" | awk -F'|' -v n="$INPUT" '$1 == n {print $2}')

if [ -z "$SCRIPT_NAME" ]; then
  printf "${RED}✖ Invalid selection${RESET}\n"
  exit 1
fi

# ---- Run script ----
printf "\n${GREEN}▶ Running:${RESET} ${BOLD}npm run %s${RESET}\n\n" "$SCRIPT_NAME"
npm run "$SCRIPT_NAME"
