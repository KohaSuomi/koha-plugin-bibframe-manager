import { usePluginApi } from '../composables/api.js';

export default {
    name: 'MatchCandidates',
    setup() {
        const api = usePluginApi();
        const loading = Vue.ref(false);
        const error = Vue.ref(null);
        const status = Vue.ref('pending');
        const candidates = Vue.ref([]);
        const total = Vue.ref(0);
        const offset = Vue.ref(0);
        const limit = 50;

        const load = async (reset = true) => {
            if (reset) {
                offset.value = 0;
                candidates.value = [];
            }
            loading.value = true;
            error.value = null;
            try {
                const res = await api.getMatchCandidates(status.value, limit, offset.value);
                const rows = (res && res.candidates) ? res.candidates : [];
                candidates.value = reset ? rows : candidates.value.concat(rows);
                total.value = (res && typeof res.total === 'number') ? res.total : candidates.value.length;
                offset.value += rows.length;
            } catch (err) {
                error.value = err.message || 'Failed to load candidates';
            } finally {
                loading.value = false;
            }
        };

        const loadMore = () => load(false);

        return { loading, error, status, candidates, total, load, loadMore };
    },
    template: `
    <div class="card mt-4">
        <div class="card-header" style="background-color: #6c757d; color: white;">
            <h5><i class="fas fa-object-group"></i> Work match candidates</h5>
        </div>
        <div class="card-body">
            <div class="row mb-2">
                <div class="col-md-3">
                    <select v-model="status" class="form-select form-select-sm">
                        <option value="pending">pending</option>
                        <option value="accepted">accepted</option>
                        <option value="rejected">rejected</option>
                        <option value="skipped">skipped</option>
                        <option value="reverted">reverted</option>
                    </select>
                </div>
                <div class="col-md-3">
                    <button class="btn btn-sm btn-primary" @click="load(true)" :disabled="loading">
                        <i class="fas" :class="loading ? 'fa-spinner fa-spin' : 'fa-search'"></i>
                        {{ loading ? 'Loading...' : 'Load' }}
                    </button>
                </div>
                <div class="col-md-6 text-end text-muted small" v-if="total">
                    Showing {{ candidates.length }} of {{ total }}
                </div>
            </div>

            <div v-if="error" class="alert alert-danger py-2">{{ error }}</div>

            <div class="table-responsive" v-if="candidates.length">
                <table class="table table-sm table-striped">
                    <thead>
                        <tr>
                            <th>ID</th>
                            <th>Tier</th>
                            <th>Relationship</th>
                            <th>Status</th>
                            <th>Work A</th>
                            <th>Work B</th>
                            <th>Evidence</th>
                        </tr>
                    </thead>
                    <tbody>
                        <tr v-for="c in candidates" :key="c.id">
                            <td>{{ c.id }}</td>
                            <td>{{ c.match_tier }}</td>
                            <td>{{ c.relationship_type }}</td>
                            <td>{{ c.status }}</td>
                            <td><small>{{ c.label_a }}</small></td>
                            <td><small>{{ c.label_b }}</small></td>
                            <td>
                                <details>
                                    <summary>show</summary>
                                    <pre class="small mb-0">{{ JSON.stringify(c.evidence, null, 2) }}</pre>
                                </details>
                            </td>
                        </tr>
                    </tbody>
                </table>
            </div>

            <div v-if="!loading && candidates.length === 0" class="text-muted small">
                No candidates for the selected status.
            </div>

            <div class="text-center mt-2" v-if="candidates.length < total">
                <button class="btn btn-sm btn-outline-secondary" @click="loadMore" :disabled="loading">
                    Load more
                </button>
            </div>
        </div>
    </div>
    `
};