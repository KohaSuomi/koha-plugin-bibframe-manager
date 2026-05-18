import { useBibframeStore } from '../store/index.js';
import { useSearchStore } from '../store/search.js';

export default {
    name: 'SearchRecords',
    setup() {
        const store = useBibframeStore();
        const search = useSearchStore();

        const handleSearch = () => {
            search.searchByBiblionumber();
        };

        const handleConvert = () => {
            store.convertRecord(search.currentRecord.biblio_id);
        }
        
        return {
            store,
            search,
            handleSearch,
            handleConvert
        };
    },
    template: `
    <div class="sidebar">
        <div class="mb-4">
            <h4><i class="fas fa-search"></i> Search Records</h4>
            
            <!-- Error Alert -->
            <div v-if="search.error" class="alert alert-danger alert-dismissible fade show" role="alert">
                <i class="fas fa-exclamation-triangle"></i> {{ search.error }}
                <button type="button" class="btn-close" @click="search.clearError()"></button>
            </div>
            
            <!-- Success Alert -->
            <div v-if="search.success" class="alert alert-success alert-dismissible fade show" role="alert">
                <i class="fas fa-check-circle"></i> {{ search.success }}
                <button type="button" class="btn-close" @click="search.clearSuccess()"></button>
            </div>
            
            <form @submit.prevent="handleSearch" class="mb-3">
                <div class="input-group">
                    <input 
                        v-model="search.biblionumber" 
                        type="text" 
                        class="form-control" 
                        placeholder="Enter biblionumber..."
                        :disabled="search.loading"
                    />
                    <button type="submit" class="btn btn-primary" :disabled="search.loading">
                        <i class="fas" :class="search.loading ? 'fa-spinner fa-spin' : 'fa-search'"></i>
                        {{ search.loading ? 'Loading...' : 'Load Record' }}
                    </button>
                </div>
            </form>
            
            <!-- Display loaded record info -->
            <div class="card">
                <div class="card-body">
                    <div v-if="search.currentRecord">
                        <h5 class="card-title">
                            <i class="fas fa-book"></i> Loaded Record
                        </h5>
                        <dl class="row mb-0">
                            <dt class="col-sm-3">Biblionumber:</dt>
                            <dd class="col-sm-9">{{ search.currentRecord.biblio_id }}</dd>
                            
                            <dt class="col-sm-3">Title:</dt>
                            <dd class="col-sm-9">{{ search.currentRecord.title || 'N/A' }}</dd>
                            
                            <dt class="col-sm-3">Author:</dt>
                            <dd class="col-sm-9">{{ search.currentRecord.author || 'N/A' }}</dd>
                        </dl>
                        <button @click="handleConvert" class="btn btn-sm btn-primary">
                            <i class="fas fa-plus"></i> Convert to Bibframe
                        </button>
                    </div>
                    <div v-else class="text-muted">
                        <i class="fas fa-info-circle"></i> No record loaded.
                    </div>
                </div>
            </div>
        </div>
    </div>
    `
};