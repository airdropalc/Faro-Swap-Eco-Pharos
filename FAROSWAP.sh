#!/bin/bash
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

BOT_DIR="FAROSWAP_BOT"
NODE_SCRIPT_NAME="index.js"
SCREEN_SESSION_NAME="Faroswap"
ENV_FILE=".env"

create_node_script() {
cat > "$BOT_DIR/$NODE_SCRIPT_NAME" << 'EOF'
const axios = require('axios');
const ethers = require('ethers');
const dotenv = require('dotenv');
const readline = require('readline');
const fs = require('fs');

dotenv.config();

const ERC20_ABI = [
  "function balanceOf(address owner) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)"
];

async function buildFallbackProvider(rpcUrls, chainId, name) {
  const provider = new ethers.JsonRpcProvider(rpcUrls[0], { chainId, name });
  return {
    getProvider: async () => {
      for (let i = 0; i < 3; i++) {
        try {
          await provider.getBlockNumber();
          return provider;
        } catch (e) {
          if (e.code === 'UNKNOWN_ERROR' && e.error && e.error.code === -32603) {
            console.log(`${colors.yellow}[⚠] RPC busy, retrying ${i + 1}/3...${colors.reset}`);
            await new Promise(r => setTimeout(r, 2000));
            continue;
          }
          throw e;
        }
      }
      throw new Error('All RPC retries failed');
    }
  };
}

const colors = {
  reset: "\x1b[0m",
  cyan: "\x1b[36m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  red: "\x1b[31m",
  white: "\x1b[37m",
  bold: "\x1b[1m",
  blue: "\x1b[34m",
  magenta: "\x1b[35m"
};

const logger = {
  info: (msg) => console.log(`${colors.green}[✓] ${msg}${colors.reset}`),
  warn: (msg) => console.log(`${colors.yellow}[⚠] ${msg}${colors.reset}`),
  error: (msg) => console.log(`${colors.red}[✗] ${msg}${colors.reset}`),
  success: (msg) => console.log(`${colors.green}[✅] ${msg}${colors.reset}`),
  loading: (msg) => console.log(`${colors.cyan}[⟳] ${msg}${colors.reset}`),
  step: (msg) => console.log(`${colors.white}[➤] ${msg}${colors.reset}`),
  countdown: (msg) => process.stdout.write(`\r${colors.blue}[⏰] ${msg}${colors.reset}`),
  banner: () => {
    console.log(`${colors.cyan}${colors.bold}`);
    console.log(`----------------------`);
    console.log(`  Faroswap Auto Bot   `);
    console.log(`----------------------${colors.reset}`);
    console.log();
  }
};

const TOKENS = {
  PHRS: '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE',
  USDT: '0xD4071393f8716661958F766DF660033b3d35fD29'
};

const PHAROS_CHAIN_ID = 688688;
const PHAROS_RPC_URLS = ['https://testnet.dplabs-internal.com'];
const DODO_ROUTER = '0x73CAfc894dBfC181398264934f7Be4e482fc9d40';
const PHRS_TO_USDT_AMOUNT = ethers.parseEther('0.00245');
const USDT_TO_PHRS_AMOUNT = ethers.parseUnits('1', 6);

const USER_AGENTS = [
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Safari/537.36',
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.101 Safari/537.36'
];

function getRandomUserAgent() {
  return USER_AGENTS[Math.floor(Math.random() * USER_AGENTS.length)];
}

function loadPrivateKeys() {
  const keys = [];
  let i = 1;
  while (process.env[`PRIVATE_KEY_${i}`]) {
    const pk = process.env[`PRIVATE_KEY_${i}`];
    if (pk.startsWith('0x') && pk.length === 66) {
      keys.push(pk);
    } else {
      logger.warn(`Invalid PRIVATE_KEY_${i} in .env, skipping...`);
    }
    i++;
  }
  return keys;
}

async function fetchWithTimeout(url, timeout = 15000) {
  try {
    const source = axios.CancelToken.source();
    const timeoutId = setTimeout(() => source.cancel('Timeout'), timeout);
    const res = await axios.get(url, {
      cancelToken: source.token,
      headers: {
        'accept': 'application/json, text/plain, */*',
        'accept-language': 'en-US,en;q=0.8',
        'priority': 'u=1, i',
        'sec-ch-ua': '"Not)A;Brand";v="8", "Chromium";v="138", "Brave";v="138"',
        'sec-ch-ua-mobile': '?0',
        'sec-ch-ua-platform': '"Windows"',
        'sec-fetch-dest': 'empty',
        'sec-fetch-mode': 'cors',
        'sec-fetch-site': 'cross-site',
        'sec-gpc': '1',
        'Referer': 'https://faroswap.xyz/',
        'User-Agent': getRandomUserAgent()
      }
    });
    clearTimeout(timeoutId);
    return res;
  } catch (err) {
    throw new Error('Timeout or network error');
  }
}

async function robustFetchDodoRoute(url) {
  for (let i = 0; i < 5; i++) {
    try {
      const res = await fetchWithTimeout(url);
      const data = res.data;
      if (data.status !== -1) return data;
      logger.warn(`Retry ${i + 1} DODO API status -1`);
    } catch (e) {
      logger.warn(`Retry ${i + 1} failed: ${e.message}`);
    }
    await new Promise(r => setTimeout(r, 2000));
  }
  throw new Error('DODO API permanently failed');
}

async function fetchDodoRoute(fromAddr, toAddr, userAddr, amountWei) {
  const deadline = Math.floor(Date.now() / 1000) + 600;
  const url = `https://api.dodoex.io/route-service/v2/widget/getdodoroute?chainId=${PHAROS_CHAIN_ID}&deadLine=${deadline}&apikey=a37546505892e1a952&slippage=3.225&source=dodoV2AndMixWasm&toTokenAddress=${toAddr}&fromTokenAddress=${fromAddr}&userAddr=${userAddr}&estimateGas=true&fromAmount=${amountWei}`;
  try {
    const result = await robustFetchDodoRoute(url);
    if (!result.data || !result.data.data) {
      throw new Error('Invalid DODO API response: missing data field');
    }
    logger.success('DODO Route Info fetched successfully');
    return result.data;
  } catch (err) {
    logger.error(`DODO API fetch failed: ${err.message}`);
    throw err;
  }
}

async function approveToken(wallet, tokenAddr, amount) {
  if (tokenAddr === TOKENS.PHRS) return true;
  const contract = new ethers.Contract(tokenAddr, ERC20_ABI, wallet);
  try {
    const balance = await contract.balanceOf(wallet.address);
    if (balance < amount) {
      logger.error(`Insufficient USDT balance: ${ethers.formatUnits(balance, 6)} USDT`);
      return false;
    }
    const allowance = await contract.allowance(wallet.address, DODO_ROUTER);
    if (allowance >= amount) {
      logger.info('Token already approved');
      return true;
    }
    logger.step(`Approving ${ethers.formatUnits(amount, 6)} USDT for DODO router`);
    const tx = await contract.approve(DODO_ROUTER, amount);
    logger.success(`Approval TX sent: ${tx.hash}`);
    await tx.wait();
    logger.success('Approval confirmed');
    return true;
  } catch (e) {
    logger.error(`Approval failed: ${e.message}`);
    return false;
  }
}

async function executeSwap(wallet, routeData, fromAddr, amount) {
  if (fromAddr !== TOKENS.PHRS) {
    const approved = await approveToken(wallet, fromAddr, amount);
    if (!approved) throw new Error('Token approval failed');
  }
  try {
    if (!routeData.data || routeData.data === '0x') {
      throw new Error('Invalid transaction data from DODO API');
    }
    const tx = await wallet.sendTransaction({
      to: routeData.to,
      data: routeData.data,
      value: BigInt(routeData.value),
      gasLimit: BigInt(routeData.gasLimit || 500000)
    });
    logger.success(`Swap Transaction sent! TX Hash: ${tx.hash}`);
    await tx.wait();
    logger.success('Transaction confirmed!');
  } catch (e) {
    logger.error(`Swap TX failed: ${e.message}`);
    throw e;
  }
}

async function batchSwap(wallet, count) {
  const swaps = [];
  for (let i = 0; i < count; i++) {
    swaps.push(i % 2 === 0 ?
      { from: TOKENS.PHRS, to: TOKENS.USDT, amount: PHRS_TO_USDT_AMOUNT, decimals: 18 } :
      { from: TOKENS.USDT, to: TOKENS.PHRS, amount: USDT_TO_PHRS_AMOUNT, decimals: 6 }
    );
  }

  for (let i = 0; i < swaps.length; i++) {
    const { from, to, amount, decimals } = swaps[i];
    const pair = from === TOKENS.PHRS ? 'PHRS -> USDT' : 'USDT -> PHRS';
    logger.step(`Swap #${i + 1} of ${count}: ${pair}`);
    try {
      const data = await fetchDodoRoute(from, to, wallet.address, amount);
      await executeSwap(wallet, data, from, amount);
    } catch (e) {
      logger.error(`Swap #${i + 1} failed: ${e.message}`);
    }
    await new Promise(r => setTimeout(r, 2000));
  }
}

async function showCountdown() {
  const now = new Date();
  const tomorrow = new Date(now);
  tomorrow.setDate(now.getDate() + 1);
  tomorrow.setHours(0, 0, 0, 0);

  return new Promise(resolve => {
    const interval = setInterval(() => {
      const remaining = tomorrow - new Date();
      if (remaining <= 0) {
        clearInterval(interval);
        process.stdout.write('\n');
        resolve();
        return;
      }
      const hours = Math.floor(remaining / (1000 * 60 * 60));
      const minutes = Math.floor((remaining % (1000 * 60 * 60)) / (1000 * 60));
      const seconds = Math.floor((remaining % (1000 * 60)) / 1000);
      logger.countdown(`Next swap cycle in ${hours}h ${minutes}m ${seconds}s`);
    }, 1000);
  });
}

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

function question(query) {
  return new Promise(resolve => rl.question(query, resolve));
}

(async () => {
  logger.banner();
  const fallbackProvider = await buildFallbackProvider(PHAROS_RPC_URLS, PHAROS_CHAIN_ID, 'pharos');
  const provider = await fallbackProvider.getProvider();
  const privateKeys = loadPrivateKeys();

  if (privateKeys.length === 0) {
    logger.error('No valid private keys found in .env. Please configure your private key.');
    process.exit(1);
  }

  try {
    const wallet = new ethers.Wallet(privateKeys[0], provider);
    logger.success(`Wallet loaded: ${wallet.address}`);

    while (true) {
      const count = await question(`${colors.cyan}How many swaps to perform (PHRS-USDT/USDT-PHRS)? ${colors.reset}`);
      try {
        const countNum = parseInt(count);
        if (isNaN(countNum) || countNum < 1) throw new Error('Invalid swap count');
        await batchSwap(wallet, countNum);
        logger.success('Swap cycle completed!');
        logger.step('Waiting for next daily cycle...');
        await showCountdown();
      } catch (e) {
        logger.error(`Error: ${e.message}`);
      }
    }
  } catch (err) {
    logger.error(`Wallet setup failed: ${err.message}`);
    process.exit(1);
  }
})();
EOF
}

install_dependencies() {
    echo -e "${CYAN}➤ Installing required NodeJS packages...${NC}"
    (cd "$BOT_DIR" && npm install axios ethers@latest dotenv readline)
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Dependencies installed successfully.${NC}"
    else
        echo -e "${RED}✗ Failed to install dependencies. Please check your npm and internet connection.${NC}"
    fi
    echo ""
    read -n 1 -s -r -p "Press any key to return to the menu..."
}

configure_wallet() {
    echo -e "${CYAN}➤ Wallet Configuration${NC}"
    echo -e "${YELLOW}Please enter your private key. It will not be displayed on screen.${NC}"
    read -sp "Enter Private Key: " private_key
    echo ""

    if [[ "$private_key" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
        echo "PRIVATE_KEY_1=${private_key}" > "$BOT_DIR/$ENV_FILE"
        echo -e "${GREEN}✓ Private key saved to $BOT_DIR/$ENV_FILE successfully.${NC}"
    else
        echo -e "${RED}✗ Invalid private key format. It should be 66 characters long and start with '0x'.${NC}"
    fi
    echo ""
    read -n 1 -s -r -p "Press any key to return to the menu..."
}

run_bot() {
    if [ ! -f "$BOT_DIR/$ENV_FILE" ]; then
        echo -e "${RED}✗ Configuration file ($ENV_FILE) not found!${NC}"
        echo -e "${YELLOW}Please configure your wallet first (Option 2).${NC}"
    else
        echo -e "${CYAN}➤ Starting the bot in a background 'screen' session named '${SCREEN_SESSION_NAME}'...${NC}"
        (cd "$BOT_DIR" && screen -dmS "$SCREEN_SESSION_NAME" node "$NODE_SCRIPT_NAME")
        echo -e "${GREEN}✓ Bot has been started.${NC}"
        echo -e "${YELLOW}IMPORTANT: To view the bot's output, use Option 4 (Check Bot Status).${NC}"
        echo -e "${YELLOW}To detach from the session window after checking, press: ${CYAN}CTRL+A${YELLOW} then ${CYAN}D${NC}"
    fi
    echo ""
    read -n 1 -s -r -p "Press any key to return to the menu..."
}

check_status() {
    echo -e "${CYAN}➤ Attaching to screen session '${SCREEN_SESSION_NAME}'...${NC}"
    echo -e "${YELLOW}To detach and return to the terminal, press: ${CYAN}CTRL+A${YELLOW} then ${CYAN}D${NC}"
    sleep 2
    screen -r "$SCREEN_SESSION_NAME"
    echo -e "\n${GREEN}Returned from screen session.${NC}"
    echo ""
    read -n 1 -s -r -p "Press any key to return to the menu..."
}

stop_bot() {
    echo -e "${CYAN}➤ Attempting to stop the bot...${NC}"
    if screen -list | grep -q "$SCREEN_SESSION_NAME"; then
        screen -X -S "$SCREEN_SESSION_NAME" quit
        echo -e "${GREEN}✓ Bot session '${SCREEN_SESSION_NAME}' has been stopped.${NC}"
    else
        echo -e "${YELLOW}⚠ Bot session '${SCREEN_SESSION_NAME}' is not currently running.${NC}"
    fi
    echo ""
    read -n 1 -s -r -p "Press any key to return to the menu..."
}

if [ ! -d "$BOT_DIR" ]; then
    echo "Creating bot directory: $BOT_DIR"
    mkdir "$BOT_DIR"
fi

if [ ! -f "$BOT_DIR/$NODE_SCRIPT_NAME" ]; then
    echo "Creating NodeJS script: $NODE_SCRIPT_NAME"
    create_node_script
fi

while true; do
    clear
    echo -e "${CYAN}===============================${NC}"
    echo -e "${CYAN}       FAROSWAP BY MOARU       ${NC}"
    echo -e "${CYAN}===============================${NC}"
    echo -e "Please choose an option:"
    echo -e "1. ${GREEN}Install Dependencies${NC} (Run this first)"
    echo -e "2. ${GREEN}Configure Wallet${NC} (Set your private key)"
    echo -e "3. ${GREEN}Run Bot${NC} (Starts the swapping process)"
    echo -e "4. ${YELLOW}Check Bot Status${NC} (View the bot's live output)"
    echo -e "5. ${RED}Stop Bot${NC}"
    echo -e "0. ${RED}Exit${NC}"
    echo -e "${CYAN}-------------------------------${NC}"
    read -p "Enter your choice [0-5]: " choice

    case $choice in
        1)
            install_dependencies
            ;;
        2)
            configure_wallet
            ;;
        3)
            run_bot
            ;;
        4)
            check_status
            ;;
        5)
            stop_bot
            ;;
        0)
            echo "Exiting. Goodbye!"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option. Please try again.${NC}"
            sleep 2
            ;;
    esac
done
