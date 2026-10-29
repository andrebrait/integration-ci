# integration config for /Users/andre/git/RTLPlayground
FORK_REMOTE=fork
UPSTREAM=logicog/RTLPlayground
BRANCH=integration/switches
BASE=upstream/main
UPSTREAM_MAIN_REF=upstream/main

# Third-party carries and fork-only drafts; original upstream heads are never rewritten.
# 615 includes our SNMP followups/UI; its integration-only RX/space adaptation
# lives in fixups/Users--andre--git--RTLPlayground/615-*.patch.
EXTRA_PRS='589=carry/pr-589 592=carry/pr-592 593=carry/pr-593 600=carry/pr-600 605=carry/pr-605 615=carry/pr-615 andrebrait/RTLPlayground#1=feat/lldp-linkdown-forget andrebrait/RTLPlayground#2=feat/lldp-nb-sysdesc andrebrait/RTLPlayground#3=feat/lldp-tlv-switches andrebrait/RTLPlayground#4=feat/lldp-warning-details'

# The LLDP carries follow DrDoof's own stack (589 > 592 > 593 > 605) since
# 587, 588 and 590 were merged; each squash contributes only its diff.
STACKED_PRS='592:589 593:592 605:593 andrebrait/RTLPlayground#1:589 andrebrait/RTLPlayground#2:593 andrebrait/RTLPlayground#3:600 andrebrait/RTLPlayground#4:605'

# No build, test, CI dispatch, or deployment hooks: firmware is built manually.
