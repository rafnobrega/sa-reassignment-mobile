import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getReassignmentContext from '@salesforce/apex/SAReassignmentController.getReassignmentContext';
import reassignAppointment from '@salesforce/apex/SAReassignmentController.reassignAppointment';

export default class SaReassignment extends LightningElement {
    @api recordId;

    context;
    selectedResourceId;
    selectedResourceName;
    bypassWarning = false;
    isLoading = true;
    isReassigning = false;
    showSuccess = false;
    error;

    @wire(getReassignmentContext, { serviceAppointmentId: '$recordId' })
    wiredContext({ data, error }) {
        this.isLoading = false;
        if (data) {
            // Deep clone and enrich with UI state
            this.context = this.enrichContext(JSON.parse(JSON.stringify(data)));
            this.error = undefined;
        } else if (error) {
            this.error = this.reduceError(error);
            this.context = undefined;
        }
    }

    /**
     * Adds UI-specific properties (cardClass, isSelected) to each eligible resource.
     */
    enrichContext(ctx) {
        if (ctx.eligibleResources) {
            ctx.eligibleResources = ctx.eligibleResources.map(r => ({
                ...r,
                isSelected: r.resourceId === this.selectedResourceId,
                cardClass: this.computeCardClass(r.resourceId)
            }));
        }
        return ctx;
    }

    computeCardClass(resourceId) {
        const base = 'slds-box slds-box_xx-small slds-m-bottom_xx-small resource-card';
        return resourceId === this.selectedResourceId ? base + ' selected' : base;
    }

    // ── Computed Properties ──

    get showNoResourceError() {
        return !this.isLoading && !this.showSuccess && !this.showTerminalStatus && this.context && !this.context.userHasResource;
    }

    get showTerminalStatus() {
        return !this.isLoading && !this.showSuccess && this.context?.isTerminalStatus;
    }

    get showContent() {
        return !this.isLoading && !this.showSuccess && !this.showTerminalStatus && this.context && this.context.userHasResource;
    }

    get crewStatusLabel() {
        if (this.context?.userInCrew) {
            return this.context.crewName;
        }
        return 'No Crew';
    }

    get crewBadgeClass() {
        return this.context?.userInCrew ? 'crew-badge' : 'no-crew-badge';
    }

    get showCrewWarning() {
        return !this.context?.userInCrew &&
            this.context?.minimumCrewSize != null &&
            this.context.minimumCrewSize > 1;
    }

    get showNoCrewInfo() {
        return !this.context?.userInCrew &&
            (this.context?.minimumCrewSize == null || this.context.minimumCrewSize <= 1);
    }

    get crewWarningMessage() {
        return `This job may require a crew-based assignment (Minimum Crew Size: ${this.context?.minimumCrewSize}). Reassigning individually may affect scheduling.`;
    }

    get resourceListLabel() {
        if (this.context?.userInCrew) {
            return `Crew Members (${this.context.crewName})`;
        }
        return 'Available Technicians';
    }

    get showResourceList() {
        // In crew mode: always show
        // In non-crew mode: show if no warning, or if warning is bypassed
        if (this.context?.userInCrew) return true;
        if (this.showCrewWarning) return this.bypassWarning;
        return true;
    }

    get hasEligibleResources() {
        return this.context?.eligibleResources?.length > 0;
    }

    get isReassignDisabled() {
        return !this.selectedResourceId || this.isReassigning;
    }

    // ── Event Handlers ──

    handleResourceSelect(event) {
        const resourceId = event.currentTarget.dataset.resourceId;
        if (this.selectedResourceId === resourceId) {
            // Deselect
            this.selectedResourceId = null;
            this.selectedResourceName = null;
        } else {
            this.selectedResourceId = resourceId;
            const resource = this.context.eligibleResources.find(r => r.resourceId === resourceId);
            this.selectedResourceName = resource?.resourceName;
        }
        // Re-enrich to update card classes
        this.context = this.enrichContext({ ...this.context });
    }

    handleResourceKeydown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleResourceSelect(event);
        }
    }

    handleBypassChange(event) {
        this.bypassWarning = event.target.checked;
    }

    async handleReassign() {
        if (!this.selectedResourceId) return;

        this.isReassigning = true;
        try {
            await reassignAppointment({
                serviceAppointmentId: this.recordId,
                newResourceId: this.selectedResourceId,
                crewId: this.context.userInCrew ? this.context.crewId : null
            });

            this.showSuccess = true;
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Success',
                    message: `Appointment reassigned to ${this.selectedResourceName}`,
                    variant: 'success'
                })
            );

            // Refresh the record page
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Reassignment Failed',
                    message: this.reduceError(error),
                    variant: 'error'
                })
            );
        } finally {
            this.isReassigning = false;
        }
    }

    /**
     * Extracts a readable error message from various Apex error shapes.
     */
    reduceError(error) {
        if (typeof error === 'string') return error;
        if (error?.body?.message) return error.body.message;
        if (error?.message) return error.message;
        if (Array.isArray(error?.body)) return error.body.map(e => e.message).join(', ');
        return 'An unexpected error occurred.';
    }
}
