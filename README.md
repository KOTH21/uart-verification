# UART TX/RX Verification Environment (SystemVerilog)

A self-contained **SystemVerilog verification environment** for validating a UART transmitter and receiver pair using constrained-random stimulus, scoreboarding, functional coverage, and SystemVerilog Assertions (SVA).

The environment is designed as a learning-oriented alternative to UVM while still demonstrating industry-standard verification concepts such as interfaces, virtual interfaces, mailboxes, coverage-driven verification, assertions, and transaction-level testbench architecture.

---

## Project Overview

This project verifies a UART loopback system:

```
AXI-Stream Source
        │
        ▼
   UART TX (DUT)
        │
      txd
        │
   UART RX (DUT)
        │
        ▼
AXI-Stream Sink
```

The verification environment automatically generates stimulus, drives transactions into the transmitter, monitors the receiver output, compares expected vs. actual results, collects coverage, and continuously checks protocol properties using assertions.

### Verification Goals

The environment verifies:

* UART TX serializes bytes correctly

  * Start bit = 0
  * 8 data bits (LSB first)
  * Stop bit = 1
* UART RX reconstructs transmitted bytes correctly
* Loopback integrity (TX byte == RX byte)
* Back-to-back frame handling
* All 256 byte values transmit correctly
* Reset behavior returns the DUT to a known idle state

---

## DUT Source

The UART transmitter and receiver RTL are based on the excellent open-source UART implementation by **Alex Forencich**.

* Author: Alex Forencich
* License: MIT License

Repository:

https://github.com/alexforencich/verilog-uart

All credit for the UART RTL implementation belongs to the original author.

---

## Verification Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     uart_tb_top.sv                          │
│                                                             │
│  ┌─────────────┐    ┌──────────────────────────────────┐    │
│  │  uart_if    │◄──►│  uart_driver                     │    │
│  │             │    │  uart_monitor                    │    │
│  └──────┬──────┘    └──────────────────────────────────┘    │
│         │                                                   │
│  ┌──────▼──────┐     ┌──────────────────────────────────┐   │
│  │  uart_tx    │     │  uart_scoreboard                 │   │
│  │   (DUT)     │     │  Expected vs Actual Comparison   │   │
│  └──────┬──────┘     └──────────────────────────────────┘   │
│         │                                                   │
│      txd loopback                                           │
│         │                                                   │
│  ┌──────▼──────┐     ┌──────────────────────────────────┐   │
│  │  uart_rx    │     │  uart_sva                        │   │
│  │   (DUT)     │     │  Protocol Assertions             │   │
│  └─────────────┘     └──────────────────────────────────┘   │
│                                                             │
│  uart_transaction                                           │
│  uart_coverage                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Key Verification Features

### Constrained-Random Testing

Randomized transaction objects generate legal UART traffic automatically:

```systemverilog
rand logic [7:0] data;
```

This enables broad stimulus exploration without writing large directed test suites.

### Scoreboard

The monitor captures:

* Expected TX transactions
* Actual RX transactions

A scoreboard compares both streams and reports mismatches automatically.

### Functional Coverage

Coverage tracks:

* Data values
* Idle gap categories
* Burst lengths
* Critical cross combinations

Coverage-driven stimulus helps ensure important scenarios are exercised.

### SystemVerilog Assertions (SVA)

Always-on protocol checking verifies:

* Idle line remains high
* Start bit is valid
* AXI-Stream handshake correctness
* Data stability while stalled
* RX valid pulse width
* No X/Z values on serial output

Assertions catch protocol violations even when a test is not explicitly checking for them.

---

## SystemVerilog Concepts Demonstrated

This project intentionally showcases core verification skills commonly expected in ASIC/FPGA verification roles.

### Interfaces and Modports

Encapsulate DUT connectivity and enforce signal directionality.

### Clocking Blocks

Eliminate testbench/DUT race conditions.

### Classes and Randomization

Transaction-level stimulus generation using:

```systemverilog
rand
constraint
randomize()
```

### Virtual Interfaces

Connect class-based components to RTL interfaces.

### Mailboxes

Thread-safe communication between:

* Generator
* Driver
* Monitor
* Scoreboard

### fork/join_none

Concurrent execution of verification components.

### Functional Coverage

Coverage collection using:

* covergroup
* coverpoint
* cross coverage

### SystemVerilog Assertions

Temporal protocol verification using SVA.

---

## Test Plan

### Smoke Test

Directed verification using:

```
0xA5
```

Confirms basic TX → RX functionality.

### Random Test

50 randomized transactions used to improve coverage.

### Stress Test

Exercises:

* Corner byte values
* Back-to-back frames
* Burst traffic
* Remaining coverage bins

---

## UART Configuration

| Parameter       | Value      |
| --------------- | ---------- |
| Clock Frequency | 50 MHz     |
| Clock Period    | 20 ns      |
| Baud Rate       | 115200     |
| Oversampling    | 8x         |
| Prescale        | 54         |
| Bit Period      | 432 clocks |
| UART Frame      | 10 bits    |

---

## Running in EDA Playground

### Simulator

* Aldec Riviera-PRO

### Compile Options

```text
+define+RIVIERA -sv
```

### File Organization

#### Design Pane

```text
uart_tx.v
uart_rx.v
```

#### Testbench Pane

```text
uart_if.sv
uart_transaction.sv
uart_driver_monitor.sv
uart_scoreboard_coverage.sv
uart_sva.sv
uart_tb_top.sv
```

Enable:

```text
Open EPWave after run
```

to inspect UART waveforms.

---

## Live Demo

EDA Playground:

PASTE_YOUR_EDA_PLAYGROUND_LINK_HERE

Recruiters and reviewers can run the project directly in a browser without installing any tools.

---

## Future Extensions

Potential enhancements include:

* Migration to UVM
* UART parity support
* Error injection tests
* Coverage closure automation
* Formal verification using existing SVA properties
* Multi-UART system-level verification

---

## Skills Demonstrated

This project demonstrates practical experience with:

* SystemVerilog Verification
* Constrained-Random Testing
* Functional Coverage
* SystemVerilog Assertions (SVA)
* Scoreboarding
* Transaction-Level Verification
* Verification Architecture Design
* FPGA/ASIC Verification Methodology

These concepts form the foundation of modern verification flows and map directly to methodologies used in professional ASIC and FPGA development environments.
