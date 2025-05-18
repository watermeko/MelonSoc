#include "VSOC.h"
#include "verilated.h"
#include <iostream>

int main(int argc, char** argv, char** env) {
   VSOC top;
   top.clk = 0;
   while(!Verilated::gotFinish()) {
      top.clk = !top.clk;
      top.eval();
   }
   return 0;
}