#!/bin/bash

# Quick Start Script for MongoDB RAG Service
# Run this after installing MongoDB

set -e

echo "🚀 Ganithamithura RAG Service - Quick Start"
echo "==========================================="
echo ""

# Check MongoDB
echo "📊 Checking MongoDB..."
if command -v mongosh &> /dev/null; then
    if pgrep -x "mongod" > /dev/null; then
        echo "✅ MongoDB is running"
    else
        echo "⚠️  MongoDB is installed but not running"
        echo "Starting MongoDB..."
        
        if [[ "$OSTYPE" == "darwin"* ]]; then
            brew services start mongodb-community@7.0
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            sudo systemctl start mongod
        fi
        
        sleep 2
        echo "✅ MongoDB started"
    fi
else
    echo "❌ MongoDB not found!"
    echo ""
    echo "Please install MongoDB first:"
    echo "  macOS:  brew install mongodb-community@7.0"
    echo "  Ubuntu: sudo apt install mongodb-org"
    echo ""
    echo "Or see MONGODB_SETUP.md for detailed instructions"
    exit 1
fi

# Check Python version
echo ""
echo "🐍 Checking Python..."
python_version=$(python3 --version 2>&1 | awk '{print $2}')
echo "✅ Python $python_version"

# Check if virtual environment exists
if [ ! -d "venv" ]; then
    echo ""
    echo "📦 Creating virtual environment..."
    python3 -m venv venv
    echo "✅ Virtual environment created"
fi

# Activate virtual environment
echo ""
echo "🔌 Activating virtual environment..."
source venv/bin/activate

# Install dependencies
echo ""
echo "📚 Installing dependencies..."
pip install --upgrade pip -q
pip install -r requirements.txt -q
echo "✅ Dependencies installed"

# Check for .env file
if [ ! -f ".env" ]; then
    echo ""
    echo "⚙️  Creating .env file..."
    cp .env.example .env
    echo "✅ .env file created"
    echo ""
    echo "⚠️  IMPORTANT: Edit .env and add your OpenAI API key!"
    echo "   Get your key from: https://platform.openai.com/api-keys"
    echo ""
    read -p "Press Enter after you've added your API key to .env..."
else
    echo "✅ .env file exists"
fi

# Check if API key is set
if grep -q "your-openai-api-key-here" .env; then
    echo ""
    echo "⚠️  OpenAI API key not set in .env!"
    echo "   Please edit .env and add your API key"
    echo "   Get your key from: https://platform.openai.com/api-keys"
    exit 1
fi

# Test MongoDB connection
echo ""
echo "🔗 Testing MongoDB connection..."
mongosh --quiet --eval "db.runCommand({ ping: 1 })" > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "✅ MongoDB connection successful"
else
    echo "❌ Could not connect to MongoDB"
    exit 1
fi

# Start the server
echo ""
echo "🚀 Starting RAG service..."
echo "==========================================="
echo ""
echo "📊 Server will be available at:"
echo "   • API Docs: http://localhost:8000/docs"
echo "   • Health:   http://localhost:8000/health"
echo ""
echo "Press Ctrl+C to stop the server"
echo ""

python -m app.main
